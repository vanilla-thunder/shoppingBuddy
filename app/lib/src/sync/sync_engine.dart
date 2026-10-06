import 'package:drift/drift.dart';

import '../data/database.dart';
import 'sync_api.dart';

/// What one sync run did; shown on the sync screen.
class SyncReport {
  const SyncReport({required this.pushed, required this.rejected, required this.pulled});
  final int pushed;

  /// Rows the server refused (`rejected`); they stay dirty and are retried next time.
  final int rejected;
  final int pulled;
}

/// One sync run as described in docs/sync.md: push every dirty row, then pull pages until
/// the server has nothing more.
class SyncEngine {
  SyncEngine(this.db, {this.batchSize = 500});

  final AppDatabase db;
  final int batchSize;

  static const lastSeqKey = 'sync_last_seq';

  Future<SyncReport> run(SyncApi api) async {
    final (pushed, rejected) = await _push(api);
    final pulled = await _pull(api);
    return SyncReport(pushed: pushed, rejected: rejected, pulled: pulled);
  }

  Future<(int, int)> _push(SyncApi api) async {
    final products = await (db.select(db.products)..where((p) => p.dirty.equals(true))).get();
    final identifiers = await (db.select(db.identifiers)..where((i) => i.dirty.equals(true))).get();
    var pushed = 0;
    var rejected = 0;
    // All products go before any identifier, so an identifier never reaches the server
    // before the product it belongs to, even across batches.
    for (var start = 0; start < products.length; start += batchSize) {
      final batch = products.sublist(start, _end(start, products.length));
      final response = await api.push(batch, const []);
      final (done, refused) = await _clearDirty(
        {for (final p in batch) p.id: p.updatedAt},
        response.products,
        (id, stamp) => (db.update(db.products)..where((p) => p.id.equals(id) & p.updatedAt.equals(stamp)))
            .write(const ProductsCompanion(dirty: Value(false))),
      );
      pushed += done;
      rejected += refused;
    }
    for (var start = 0; start < identifiers.length; start += batchSize) {
      final batch = identifiers.sublist(start, _end(start, identifiers.length));
      final response = await api.push(const [], batch);
      final (done, refused) = await _clearDirty(
        {for (final i in batch) i.id: i.updatedAt},
        response.identifiers,
        (id, stamp) => (db.update(db.identifiers)..where((i) => i.id.equals(id) & i.updatedAt.equals(stamp)))
            .write(const IdentifiersCompanion(dirty: Value(false))),
      );
      pushed += done;
      rejected += refused;
    }
    return (pushed, rejected);
  }

  int _end(int start, int length) => start + batchSize < length ? start + batchSize : length;

  /// Clears the dirty flag of every accepted row, unless it was edited again while the push
  /// was in flight: then its `updated_at` differs from the pushed one and it stays dirty.
  Future<(int, int)> _clearDirty(
    Map<String, DateTime> sentAt,
    List<PushResult> results,
    Future<void> Function(String id, DateTime stamp) clear,
  ) async {
    final done = results.where((r) => r.done).map((r) => r.id).toList();
    await db.transaction(() async {
      for (final id in done) {
        final stamp = sentAt[id];
        if (stamp != null) await clear(id, stamp);
      }
    });
    return (done.length, results.length - done.length);
  }

  Future<int> _pull(SyncApi api) async {
    var since = await _lastSeq();
    var pulled = 0;
    while (true) {
      final page = await api.pull(since, limit: batchSize);
      // A page and its last_seq commit together, so an interrupted pull resumes cleanly.
      await db.transaction(() async {
        for (final row in page.products) {
          await _applyProduct(row);
        }
        for (final row in page.identifiers) {
          await _applyIdentifier(row);
        }
        await db.into(db.settings).insertOnConflictUpdate(
              SettingsCompanion.insert(key: lastSeqKey, value: '${page.lastSeq}'),
            );
      });
      pulled += page.products.length + page.identifiers.length;
      if (!page.hasMore || page.lastSeq <= since) return pulled;
      since = page.lastSeq;
    }
  }

  Future<int> _lastSeq() async {
    final row = await (db.select(db.settings)..where((s) => s.key.equals(lastSeqKey))).getSingleOrNull();
    return int.tryParse(row?.value ?? '') ?? 0;
  }

  // docs/sync.md, "Applying a pulled row on the client": a local edit survives only if it is
  // still unpushed and newer than the server's version.
  static bool _keepLocal(bool dirty, DateTime localUpdated, DateTime remoteUpdated) =>
      dirty && localUpdated.isAfter(remoteUpdated);

  Future<void> _applyProduct(ProductRow row) async {
    final local = await (db.select(db.products)..where((p) => p.id.equals(row.id))).getSingleOrNull();
    if (local != null && _keepLocal(local.dirty, local.updatedAt, row.updatedAt)) return;
    await db.into(db.products).insertOnConflictUpdate(row);
  }

  Future<void> _applyIdentifier(IdentifierRow row) async {
    final local = await (db.select(db.identifiers)..where((i) => i.id.equals(row.id))).getSingleOrNull();
    if (local != null && _keepLocal(local.dirty, local.updatedAt, row.updatedAt)) return;
    await db.into(db.identifiers).insertOnConflictUpdate(row);
  }
}
