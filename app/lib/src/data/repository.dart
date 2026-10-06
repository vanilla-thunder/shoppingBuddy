import 'dart:async';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../domain/categories.dart';
import '../domain/identifiers.dart';
import 'database.dart';

/// A live product with its live identifiers.
class Product {
  const Product(this.row, this.identifiers);

  final ProductRow row;
  final List<NormalizedIdentifier> identifiers;

  String get id => row.id;
}

/// Editable product fields, already validated.
class ProductDraft {
  ProductDraft({required String name, String? brand, this.rating, String? notes, String category = localCategory})
      : name = name.trim(),
        brand = _blankToNull(brand),
        notes = _blankToNull(notes),
        category = normalizeCategory(category) {
    if (this.name.isEmpty) throw const FormatException('name must not be empty');
    if (rating != null && (rating! < 1 || rating! > 5)) throw const FormatException('rating must be 1-5');
  }

  final String name;
  final String? brand;
  final int? rating;
  final String? notes;
  final String category;

  static String? _blankToNull(String? text) => (text == null || text.trim().isEmpty) ? null : text.trim();
}

class IdentifierTaken implements Exception {
  const IdentifierTaken(this.identifier, this.productId);

  final NormalizedIdentifier identifier;
  final String productId;

  @override
  String toString() => '$identifier is already assigned to another product';
}

class CategoryCount {
  const CategoryCount(this.category, this.count);

  final String category;
  final int count;
}

/// All local reads and writes. Every write marks rows dirty and stamps them with a timestamp
/// that wins last-write-wins against the version it replaces (docs/sync.md).
class ProductRepository {
  ProductRepository(this.db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  DateTime _now() => _clock().toUtc();

  /// A timestamp later than [previous], even if the clock that wrote it ran ahead of ours.
  DateTime _fresh(DateTime previous) {
    final now = _now();
    final bumped = previous.toUtc().add(const Duration(milliseconds: 1));
    return now.isAfter(bumped) ? now : bumped;
  }

  // --- reads ---

  Stream<List<Product>> watchProducts({String? category, String query = ''}) {
    final select = db.select(db.products)
      ..where((p) => p.deleted.equals(false))
      ..orderBy([(p) => OrderingTerm.asc(p.name.collate(Collate.noCase)), (p) => OrderingTerm.asc(p.id)]);
    if (category != null) select.where((p) => p.category.equals(category));

    final q = query.trim();
    if (q.isNotEmpty) {
      final pattern = '%${_escapeLike(q)}%';
      final matchingIds = db.selectOnly(db.identifiers)
        ..addColumns([db.identifiers.productId])
        ..where(db.identifiers.deleted.equals(false) & db.identifiers.value.like(pattern, escapeChar: r'\'));
      select.where((p) =>
          p.name.like(pattern, escapeChar: r'\') |
          p.brand.like(pattern, escapeChar: r'\') |
          p.id.isInQuery(matchingIds));
    }
    return _watchBoth(() async => _withIdentifiers(await select.get()));
  }

  Stream<Product?> watchProduct(String id) => _watchBoth(() => getProduct(id));

  /// The live product [id], or the product it was merged into by the server, so open screens
  /// follow a merge (docs/sync.md).
  Future<Product?> getProduct(String id) async {
    var row = await (db.select(db.products)..where((p) => p.id.equals(id))).getSingleOrNull();
    while (row != null && row.deleted && row.mergedInto != null) {
      final target = row.mergedInto!;
      row = await (db.select(db.products)..where((p) => p.id.equals(target))).getSingleOrNull();
    }
    return (row == null || row.deleted) ? null : (await _withIdentifiers([row])).single;
  }

  /// Number of products and identifiers changed here and not yet pushed.
  Stream<int> watchUnsyncedCount() => _watchBoth(() async {
        final products = db.products.id.count(filter: db.products.dirty.equals(true));
        final identifiers = db.identifiers.id.count(filter: db.identifiers.dirty.equals(true));
        final p = await (db.selectOnly(db.products)..addColumns([products])).getSingle();
        final i = await (db.selectOnly(db.identifiers)..addColumns([identifiers])).getSingle();
        return p.read(products)! + i.read(identifiers)!;
      });

  /// Finds the live product carrying [ident], following merges done by the server.
  Future<Product?> lookup(NormalizedIdentifier ident) async {
    final row = await _liveIdentifier(ident);
    if (row == null) return null;
    var product = await (db.select(db.products)..where((p) => p.id.equals(row.productId))).getSingleOrNull();
    while (product != null && product.mergedInto != null) {
      final target = product.mergedInto!;
      product = await (db.select(db.products)..where((p) => p.id.equals(target))).getSingleOrNull();
    }
    if (product == null || product.deleted) return null;
    return (await _withIdentifiers([product])).single;
  }

  Stream<List<CategoryCount>> watchCategories() {
    final count = db.products.id.count();
    final query = db.selectOnly(db.products)
      ..addColumns([db.products.category, count])
      ..where(db.products.deleted.equals(false))
      ..groupBy([db.products.category]);
    return query.watch().map((rows) {
      final result = [for (final r in rows) CategoryCount(r.read(db.products.category)!, r.read(count)!)];
      result.sort((a, b) {
        if (a.category == localCategory) return -1;
        if (b.category == localCategory) return 1;
        return a.category.compareTo(b.category);
      });
      return result;
    });
  }

  // --- writes ---

  Future<String> createProduct(ProductDraft draft, [List<NormalizedIdentifier> identifiers = const []]) {
    if (identifiers.toSet().length != identifiers.length) {
      throw const FormatException('the same identifier appears twice');
    }
    return db.transaction(() async {
      for (final ident in identifiers) {
        await _ensureFree(ident);
      }
      final id = _uuid.v4();
      final now = _now();
      await db.into(db.products).insert(ProductsCompanion.insert(
            id: id,
            name: draft.name,
            brand: Value(draft.brand),
            rating: Value(draft.rating),
            notes: Value(draft.notes),
            category: Value(draft.category),
            createdAt: now,
            updatedAt: now,
            dirty: const Value(true),
          ));
      for (final ident in identifiers) {
        await _insertIdentifier(id, ident, now);
      }
      return id;
    });
  }

  Future<void> updateProduct(String id, ProductDraft draft) => _updateProduct(
        id,
        ProductsCompanion(
          name: Value(draft.name),
          brand: Value(draft.brand),
          rating: Value(draft.rating),
          notes: Value(draft.notes),
          category: Value(draft.category),
        ),
      );

  Future<void> setRating(String id, int? rating) {
    if (rating != null && (rating < 1 || rating > 5)) throw const FormatException('rating must be 1-5');
    return _updateProduct(id, ProductsCompanion(rating: Value(rating)));
  }

  Future<void> deleteProduct(String id) => db.transaction(() async {
        await _updateProduct(id, const ProductsCompanion(deleted: Value(true)));
        final live = await (db.select(db.identifiers)
              ..where((i) => i.productId.equals(id) & i.deleted.equals(false)))
            .get();
        for (final ident in live) {
          await _tombstoneIdentifier(ident);
        }
      });

  Future<void> addIdentifier(String productId, NormalizedIdentifier ident) => db.transaction(() async {
        await _requireLive(productId);
        await _ensureFree(ident);
        await _insertIdentifier(productId, ident, _now());
      });

  /// Removes [ident] from [productId] (no-op if it isn't there).
  Future<void> removeIdentifier(String productId, NormalizedIdentifier ident) => db.transaction(() async {
        final row = await _liveIdentifier(ident);
        if (row != null && row.productId == productId) await _tombstoneIdentifier(row);
      });

  // --- settings ---

  Future<String?> getSetting(String key) async =>
      (await (db.select(db.settings)..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setSetting(String key, String? value) async {
    if (value == null) {
      await (db.delete(db.settings)..where((s) => s.key.equals(key))).go();
    } else {
      await db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));
    }
  }

  // --- helpers ---

  /// Emits [load]'s result now and again after every change to products or identifiers,
  /// since results carry both.
  Stream<T> _watchBoth<T>(Future<T> Function() load) {
    // Not an async* generator: cancelling one that waits inside drift's update stream never
    // completes, which would leak a subscription every time a screen closes.
    StreamSubscription<void>? updates;
    late final StreamController<T> controller;
    var pending = Future<void>.value();
    void reload() {
      // Chained, so results arrive in order even when updates come in quick succession.
      pending = pending.then((_) => load()).then(
        (value) => controller.isClosed ? null : controller.add(value),
        onError: (Object e, StackTrace st) => controller.isClosed ? null : controller.addError(e, st),
      );
    }

    controller = StreamController<T>(
      onListen: () {
        reload();
        updates = db
            .tableUpdates(TableUpdateQuery.onAllTables([db.products, db.identifiers]))
            .listen((_) => reload());
      },
      onCancel: () {
        updates?.cancel();
        controller.close();
      },
    );
    return controller.stream;
  }

  Future<List<Product>> _withIdentifiers(List<ProductRow> rows) async {
    if (rows.isEmpty) return const [];
    final idents = await (db.select(db.identifiers)
          ..where((i) => i.productId.isIn(rows.map((r) => r.id)) & i.deleted.equals(false))
          ..orderBy([(i) => OrderingTerm.asc(i.createdAt)]))
        .get();
    final byProduct = <String, List<NormalizedIdentifier>>{};
    for (final i in idents) {
      byProduct.putIfAbsent(i.productId, () => []).add(_toIdentifier(i));
    }
    return [for (final r in rows) Product(r, byProduct[r.id] ?? const [])];
  }

  static NormalizedIdentifier _toIdentifier(IdentifierRow row) =>
      NormalizedIdentifier(IdentifierType.fromWire(row.type), row.value, row.store);

  Future<IdentifierRow?> _liveIdentifier(NormalizedIdentifier ident) async {
    final rows = await (db.select(db.identifiers)
          ..where((i) =>
              i.type.equals(ident.type.wire) &
              i.value.equals(ident.value) &
              i.store.equals(ident.store) &
              i.deleted.equals(false))
          ..orderBy([(i) => OrderingTerm.asc(i.createdAt)])
          ..limit(1))
        .get();
    return rows.firstOrNull;
  }

  Future<ProductRow> _requireLive(String id) async {
    final row = await (db.select(db.products)..where((p) => p.id.equals(id))).getSingleOrNull();
    if (row == null || row.deleted) throw StateError('product $id not found');
    return row;
  }

  Future<void> _ensureFree(NormalizedIdentifier ident) async {
    final clash = await _liveIdentifier(ident);
    if (clash != null) throw IdentifierTaken(ident, clash.productId);
  }

  Future<void> _updateProduct(String id, ProductsCompanion changes) async {
    final current = await _requireLive(id);
    await (db.update(db.products)..where((p) => p.id.equals(id))).write(
      changes.copyWith(updatedAt: Value(_fresh(current.updatedAt)), dirty: const Value(true)),
    );
  }

  Future<void> _insertIdentifier(String productId, NormalizedIdentifier ident, DateTime now) =>
      db.into(db.identifiers).insert(IdentifiersCompanion.insert(
            id: _uuid.v4(),
            productId: productId,
            type: ident.type.wire,
            value: ident.value,
            store: Value(ident.store),
            createdAt: now,
            updatedAt: now,
            dirty: const Value(true),
          ));

  Future<void> _tombstoneIdentifier(IdentifierRow row) =>
      (db.update(db.identifiers)..where((i) => i.id.equals(row.id))).write(IdentifiersCompanion(
        deleted: const Value(true),
        updatedAt: Value(_fresh(row.updatedAt)),
        dirty: const Value(true),
      ));

  static String _escapeLike(String text) =>
      text.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
}
