import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopping_buddy/src/data/database.dart';
import 'package:shopping_buddy/src/data/repository.dart';
import 'package:shopping_buddy/src/domain/identifiers.dart';

void main() {
  late AppDatabase db;
  late ProductRepository repo;
  var clock = DateTime.utc(2026, 1, 1);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = DateTime.utc(2026, 1, 1);
    repo = ProductRepository(db, clock: () => clock);
  });
  tearDown(() => db.close());

  final milk = normalizeGtin('4006381333931');
  final butter = normalizeGtin('5901234123457');

  test('create, lookup and the rows are dirty for sync', () async {
    final id = await repo.createProduct(ProductDraft(name: ' Milk ', rating: 4), [milk]);
    final found = await repo.lookup(normalizeGtin('04006381333931'));
    expect(found!.id, id);
    expect(found.row.name, 'Milk');
    expect(found.row.category, 'local');
    expect(found.identifiers, [milk]);
    expect(found.row.dirty, isTrue);
    expect(found.row.serverSeq, isNull);
    expect(await repo.lookup(butter), isNull);
  });

  test('a taken barcode is refused', () async {
    final id = await repo.createProduct(ProductDraft(name: 'Milk'), [milk]);
    await expectLater(
      repo.createProduct(ProductDraft(name: 'Other'), [milk]),
      throwsA(isA<IdentifierTaken>().having((e) => e.productId, 'productId', id)),
    );
    final other = await repo.createProduct(ProductDraft(name: 'Other'));
    await expectLater(repo.addIdentifier(other, milk), throwsA(isA<IdentifierTaken>()));
  });

  test('edits get a timestamp later than the previous one, even if the clock is behind', () async {
    final id = await repo.createProduct(ProductDraft(name: 'Milk'));
    clock = DateTime.utc(2025, 1, 1); // clock jumped back
    await repo.setRating(id, 5);
    final row = (await repo.getProduct(id))!.row;
    expect(row.rating, 5);
    expect(row.updatedAt.isAfter(DateTime.utc(2026, 1, 1)), isTrue);
  });

  test('timestamps keep millisecond precision', () async {
    clock = DateTime.utc(2026, 1, 1, 12, 0, 0, 123);
    final id = await repo.createProduct(ProductDraft(name: 'Milk'));
    expect((await repo.getProduct(id))!.row.updatedAt, DateTime.utc(2026, 1, 1, 12, 0, 0, 123));
  });

  test('delete tombstones product and identifiers and frees the barcode', () async {
    final id = await repo.createProduct(ProductDraft(name: 'Milk'), [milk]);
    await repo.deleteProduct(id);
    expect(await repo.getProduct(id), isNull);
    expect(await repo.lookup(milk), isNull);
    final rows = await db.select(db.identifiers).get();
    expect(rows.single.deleted, isTrue);
    expect(rows.single.dirty, isTrue);
    await repo.createProduct(ProductDraft(name: 'New milk'), [milk]);
  });

  test('lookup follows server merges', () async {
    final a = await repo.createProduct(ProductDraft(name: 'A'));
    final b = await repo.createProduct(ProductDraft(name: 'B'), [milk]);
    // What a pull delivers after the server merged B into A.
    await (db.update(db.products)..where((p) => p.id.equals(b)))
        .write(ProductsCompanion(deleted: const Value(true), mergedInto: Value(a)));
    expect((await repo.lookup(milk))!.id, a);
  });

  test('search by name, brand and barcode, filtered by category', () async {
    await repo.createProduct(ProductDraft(name: 'Vollmilch', brand: 'Weihenstephan'), [milk]);
    await repo.createProduct(ProductDraft(name: 'Pizza_100%', category: 'https://www.lieferando.de/x'));
    Future<List<String>> names({String? category, String q = ''}) async =>
        (await repo.watchProducts(category: category, query: q).first).map((p) => p.row.name).toList();

    expect(await names(), ['Pizza_100%', 'Vollmilch']);
    expect(await names(category: 'local'), ['Vollmilch']);
    expect(await names(category: 'lieferando.de'), ['Pizza_100%']);
    expect(await names(q: 'weihen'), ['Vollmilch']);
    expect(await names(q: '333931'), ['Vollmilch']);
    expect(await names(q: '_100%'), ['Pizza_100%']);
    expect(await names(q: '00%'), ['Pizza_100%']);
    expect(await names(q: 'x%'), isEmpty);
  });

  test('product list updates when an identifier is added', () async {
    final id = await repo.createProduct(ProductDraft(name: 'Milk'));
    final updates = repo.watchProducts().map((ps) => ps.single.identifiers.length);
    final seen = <int>[];
    final sub = updates.listen(seen.add);
    await pumpEventQueue();
    await repo.addIdentifier(id, milk);
    await pumpEventQueue();
    await sub.cancel();
    expect(seen.first, 0);
    expect(seen.last, 1);
  });

  test('categories with counts, local first', () async {
    await repo.createProduct(ProductDraft(name: 'Pad Thai', category: 'wolt.com'));
    await repo.createProduct(ProductDraft(name: 'Milk'));
    await repo.createProduct(ProductDraft(name: 'Pizza', category: 'lieferando.de'));
    await repo.createProduct(ProductDraft(name: 'Pasta', category: 'lieferando.de'));
    final cats = await repo.watchCategories().first;
    expect([for (final c in cats) '${c.category}:${c.count}'], ['local:1', 'lieferando.de:2', 'wolt.com:1']);
  });

  test('draft validation', () {
    expect(() => ProductDraft(name: '  '), throwsFormatException);
    expect(() => ProductDraft(name: 'x', rating: 6), throwsFormatException);
    expect(() => ProductDraft(name: 'x', category: 'not valid'), throwsFormatException);
    expect(ProductDraft(name: 'x', brand: '  ').brand, isNull);
  });

  test('settings', () async {
    expect(await repo.getSetting('category'), isNull);
    await repo.setSetting('category', 'lieferando.de');
    await repo.setSetting('category', 'wolt.com');
    expect(await repo.getSetting('category'), 'wolt.com');
    await repo.setSetting('category', null);
    expect(await repo.getSetting('category'), isNull);
  });
}
