import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shopping_buddy/src/data/database.dart';
import 'package:shopping_buddy/src/data/repository.dart';
import 'package:shopping_buddy/src/domain/identifiers.dart';
import 'package:shopping_buddy/src/sync/sync_api.dart';
import 'package:shopping_buddy/src/sync/sync_engine.dart';

const token = 'test-token-not-a-secret';

/// Answers push with a fixed status per row and pull from a queue of pages.
class ScriptedServer {
  final pushes = <Map<String, dynamic>>[];
  final pullSince = <int>[];
  final pages = <Map<String, dynamic>>[];
  String Function(String id) statusFor = (_) => 'applied';
  Future<void> Function()? duringPush;

  late final client = MockClient((request) async {
    expect(request.headers['Authorization'], 'Bearer $token');
    if (request.url.path == '/sync/push') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      pushes.add(body);
      await duringPush?.call();
      List<Map<String, String>> results(String key) => [
            for (final r in body[key] as List) {'id': r['id'] as String, 'status': statusFor(r['id'] as String)},
          ];
      return http.Response(
        jsonEncode({'products': results('products'), 'identifiers': results('identifiers'), 'merges': []}),
        200,
      );
    }
    pullSince.add(int.parse(request.url.queryParameters['since']!));
    final page = pages.isEmpty
        ? {'products': [], 'identifiers': [], 'last_seq': pullSince.last, 'has_more': false}
        : pages.removeAt(0);
    return http.Response.bytes(utf8.encode(jsonEncode(page)), 200);
  });
}

Map<String, dynamic> serverProduct(String id, String name, DateTime updated, int seq, {String? mergedInto}) => {
      'id': id,
      'name': name,
      'brand': null,
      'rating': 3,
      'notes': null,
      'category': 'local',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': updated.toUtc().toIso8601String(),
      'deleted': mergedInto != null,
      'merged_into': mergedInto,
      'server_seq': seq,
    };

void main() {
  late AppDatabase db;
  late ProductRepository repo;
  late ScriptedServer server;
  late SyncApi api;
  late SyncEngine engine;
  var clock = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = DateTime.utc(2026, 1, 1, 12);
    repo = ProductRepository(db, clock: () => clock);
    server = ScriptedServer();
    api = SyncApi(baseUrl: 'http://server.test', token: token, client: server.client);
    engine = SyncEngine(db, batchSize: 2);
  });
  tearDown(() => db.close());

  Future<ProductRow> productRow(String id) => (db.select(db.products)..where((p) => p.id.equals(id))).getSingle();

  test('push sends products before identifiers, in batches, and clears dirty', () async {
    final ids = [
      for (final (name, code) in [('A', '4006381333931'), ('B', '5901234123457'), ('C', '40084107')])
        await repo.createProduct(ProductDraft(name: name), [normalizeGtin(code)]),
    ];
    final report = await engine.run(api);

    expect(server.pushes.map((p) => ((p['products'] as List).length, (p['identifiers'] as List).length)),
        [(2, 0), (1, 0), (0, 2), (0, 1)]);
    final first = (server.pushes.first['products'] as List).first as Map;
    expect(first['updated_at'], '2026-01-01T12:00:00.000Z');
    expect(first['category'], 'local');
    expect(report.pushed, 6);
    expect(await repo.watchUnsyncedCount().first, 0);
    expect((await productRow(ids.first)).dirty, isFalse);
  });

  test('a row edited while its push is in flight stays dirty', () async {
    final id = await repo.createProduct(ProductDraft(name: 'Milk'));
    server.duringPush = () async {
      clock = clock.add(const Duration(seconds: 1));
      await repo.setRating(id, 5);
    };
    await engine.run(api);
    expect((await productRow(id)).dirty, isTrue);
  });

  test('rejected rows stay dirty, all other statuses clear it', () async {
    final keep = await repo.createProduct(ProductDraft(name: 'Rejected'));
    final stale = await repo.createProduct(ProductDraft(name: 'Stale'));
    server.statusFor = (id) => id == keep ? 'rejected' : 'stale';
    final report = await engine.run(api);
    expect(report.rejected, 1);
    expect((await productRow(keep)).dirty, isTrue);
    expect((await productRow(stale)).dirty, isFalse);
  });

  test('pull applies last-write-wins and pages until has_more is false', () async {
    final newerLocal = await repo.createProduct(ProductDraft(name: 'local edit wins'));
    final olderLocal = await repo.createProduct(ProductDraft(name: 'server wins'));
    server.statusFor = (_) => 'rejected'; // keep both dirty for the pull
    clock = DateTime.utc(2026, 1, 1, 13);
    await repo.setRating(newerLocal, 1);

    final at = DateTime.utc(2026, 1, 1, 12, 30);
    server.pages.addAll([
      {
        'products': [serverProduct(newerLocal, 'server old', at, 1), serverProduct(olderLocal, 'server new', at, 2)],
        'identifiers': [],
        'last_seq': 2,
        'has_more': true,
      },
      {
        'products': [serverProduct('11111111-1111-4111-8111-111111111111', 'from web', at, 3)],
        'identifiers': [
          {
            'id': '22222222-2222-4222-8222-222222222222',
            'product_id': '11111111-1111-4111-8111-111111111111',
            'type': 'gtin',
            'value': '00000040084107',
            'store': '',
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-01T00:00:00+00:00',
            'deleted': false,
            'server_seq': 4,
          },
        ],
        'last_seq': 4,
        'has_more': false,
      },
    ]);
    final report = await engine.run(api);

    expect(server.pullSince, [0, 2]);
    expect(report.pulled, 4);
    expect((await productRow(newerLocal)).name, 'local edit wins');
    expect((await productRow(newerLocal)).dirty, isTrue);
    final overwritten = await productRow(olderLocal);
    expect((overwritten.name, overwritten.dirty, overwritten.serverSeq), ('server new', false, 2));
    expect((await repo.lookup(normalizeGtin('40084107')))!.row.name, 'from web');
    expect(await repo.getSetting(SyncEngine.lastSeqKey), '4');

    await engine.run(api);
    expect(server.pullSince.last, 4);
  });

  test('a merged product is followed to its survivor', () async {
    final loser = await repo.createProduct(ProductDraft(name: 'Phone copy'));
    const survivor = '33333333-3333-4333-8333-333333333333';
    final later = DateTime.utc(2026, 1, 2);
    server.pages.add({
      'products': [serverProduct(loser, 'Phone copy', later, 5, mergedInto: survivor), serverProduct(survivor, 'Web', later, 6)],
      'identifiers': [],
      'last_seq': 6,
      'has_more': false,
    });
    await engine.run(api);
    expect((await repo.getProduct(loser))!.id, survivor);
  });

  test('HTTP errors become readable SyncExceptions', () async {
    Future<Object?> failWith(http.Response response) async {
      final api = SyncApi(baseUrl: 'http://server.test/', token: token, client: MockClient((_) async => response));
      try {
        await api.pull(0);
        return null;
      } on SyncException catch (e) {
        return e.message;
      }
    }

    expect(await failWith(http.Response('', 401)), 'Token was refused');
    expect(await failWith(http.Response('', 404)), 'No sync API at this URL');
    expect(await failWith(http.Response('<html>', 200)), contains('Unexpected answer'));
  });

  test('a base URL with a path keeps it', () async {
    late Uri seen;
    final api = SyncApi(
      baseUrl: 'https://example.test/buddy',
      token: token,
      client: MockClient((request) async {
        seen = request.url;
        return http.Response('{"products":[],"identifiers":[],"last_seq":0,"has_more":false}', 200);
      }),
    );
    await api.pull(7);
    expect(seen.toString(), 'https://example.test/buddy/sync/pull?since=7&limit=500');
  });
}
