// Runs the sync engine against a real server. Skipped unless SB_E2E_URL and SB_E2E_TOKEN
// are set, e.g. with a dev server on an empty database:
//   SB_E2E_URL=http://127.0.0.1:8000 SB_E2E_TOKEN=... flutter test test/sync_e2e_test.dart
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shopping_buddy/src/data/database.dart';
import 'package:shopping_buddy/src/data/repository.dart';
import 'package:shopping_buddy/src/domain/identifiers.dart';
import 'package:shopping_buddy/src/sync/sync_api.dart';
import 'package:shopping_buddy/src/sync/sync_engine.dart';

final url = Platform.environment['SB_E2E_URL'];
final token = Platform.environment['SB_E2E_TOKEN'] ?? '';

void main() {
  // The test plays two devices, so it opens two databases on purpose.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('two devices sync through the server, including a duplicate-barcode merge', () async {
    final api = SyncApi(baseUrl: url!, token: token);
    final dbA = AppDatabase(NativeDatabase.memory());
    final dbB = AppDatabase(NativeDatabase.memory());
    addTearDown(dbA.close);
    addTearDown(dbB.close);
    final a = ProductRepository(dbA);
    final b = ProductRepository(dbB);
    final code = normalizeGtin('4006381333931');

    // A creates a product; B gets it.
    final milk = await a.createProduct(ProductDraft(name: 'Milch A', rating: 4), [code]);
    await SyncEngine(dbA).run(api);
    await SyncEngine(dbB).run(api);
    expect((await b.lookup(code))!.row.name, 'Milch A');

    // B edits it; A gets the edit.
    await b.setRating(milk, 2);
    await SyncEngine(dbB).run(api);
    await SyncEngine(dbA).run(api);
    expect((await a.getProduct(milk))!.row.rating, 2);

    // Both add the same new barcode as different products while offline: the server merges.
    final butter = normalizeGtin('5901234123457');
    final first = await a.createProduct(ProductDraft(name: 'Butter A'), [butter]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = await b.createProduct(ProductDraft(name: 'Butter B', rating: 5), [butter]);
    await SyncEngine(dbA).run(api);
    await SyncEngine(dbB).run(api);
    await SyncEngine(dbA).run(api);
    for (final repo in [a, b]) {
      final found = (await repo.lookup(butter))!;
      expect(found.id, first, reason: 'the older product survives');
      expect(found.row.rating, 5, reason: 'a rating set on either side is kept');
      expect((await repo.getProduct(second))!.id, first);
      expect(await repo.watchUnsyncedCount().first, 0);
    }
  }, skip: url == null ? 'set SB_E2E_URL and SB_E2E_TOKEN to run against a server' : false);
}
