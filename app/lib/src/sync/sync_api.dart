import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/database.dart';

/// Why a sync request failed, in words the sync screen can show.
class SyncException implements Exception {
  const SyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Result of one pushed row (docs/sync.md, "Push").
class PushResult {
  const PushResult(this.id, this.status);
  final String id;
  final String status;

  /// Every status except `rejected` lets the client clear its dirty flag.
  bool get done => status != 'rejected';
}

class PushResponse {
  const PushResponse(this.products, this.identifiers);
  final List<PushResult> products;
  final List<PushResult> identifiers;
}

class PullPage {
  const PullPage(this.products, this.identifiers, this.lastSeq, this.hasMore);
  final List<ProductRow> products;
  final List<IdentifierRow> identifiers;
  final int lastSeq;
  final bool hasMore;
}

/// The server's `/sync` endpoints. Rows travel as drift rows; `dirty` is local-only and
/// always false on rows coming from the server.
class SyncApi {
  SyncApi({required String baseUrl, required this.token, http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
        _client = client ?? http.Client();

  final Uri _base;
  final String token;
  final http.Client _client;
  final Duration timeout;

  Map<String, String> get _headers => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  Future<PushResponse> push(List<ProductRow> products, List<IdentifierRow> identifiers) async {
    final body = jsonEncode({
      'products': [for (final p in products) productToJson(p)],
      'identifiers': [for (final i in identifiers) identifierToJson(i)],
    });
    final json = await _send(() => _client.post(_base.resolve('sync/push'), headers: _headers, body: body));
    List<PushResult> results(String key) =>
        [for (final r in json[key] as List) PushResult(r['id'] as String, r['status'] as String)];
    return PushResponse(results('products'), results('identifiers'));
  }

  Future<PullPage> pull(int since, {int limit = 500}) async {
    final uri = _base.resolve('sync/pull').replace(queryParameters: {'since': '$since', 'limit': '$limit'});
    final json = await _send(() => _client.get(uri, headers: _headers));
    return PullPage(
      [for (final p in json['products'] as List) productFromJson(p as Map<String, dynamic>)],
      [for (final i in json['identifiers'] as List) identifierFromJson(i as Map<String, dynamic>)],
      json['last_seq'] as int,
      json['has_more'] as bool,
    );
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw const SyncException('Server did not answer in time');
    } on Exception catch (e) {
      throw SyncException('Server not reachable ($e)');
    }
    switch (response.statusCode) {
      case 200:
        try {
          return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        } on Object {
          throw const SyncException('Unexpected answer from the server (is the URL right?)');
        }
      case 401 || 403:
        throw const SyncException('Token was refused');
      case 404:
        throw const SyncException('No sync API at this URL');
      case 422:
        throw SyncException('Server rejected the data: ${utf8.decode(response.bodyBytes)}');
      default:
        throw SyncException('Server error ${response.statusCode}');
    }
  }
}

String _ts(DateTime t) => t.toUtc().toIso8601String();

Map<String, dynamic> productToJson(ProductRow p) => {
      'id': p.id,
      'name': p.name,
      'brand': p.brand,
      'rating': p.rating,
      'notes': p.notes,
      'category': p.category,
      'created_at': _ts(p.createdAt),
      'updated_at': _ts(p.updatedAt),
      'deleted': p.deleted,
    };

Map<String, dynamic> identifierToJson(IdentifierRow i) => {
      'id': i.id,
      'product_id': i.productId,
      'type': i.type,
      'value': i.value,
      'store': i.store,
      'created_at': _ts(i.createdAt),
      'updated_at': _ts(i.updatedAt),
      'deleted': i.deleted,
    };

ProductRow productFromJson(Map<String, dynamic> j) => ProductRow(
      id: j['id'] as String,
      name: j['name'] as String,
      brand: j['brand'] as String?,
      rating: j['rating'] as int?,
      notes: j['notes'] as String?,
      category: j['category'] as String,
      createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(j['updated_at'] as String).toUtc(),
      deleted: j['deleted'] as bool,
      mergedInto: j['merged_into'] as String?,
      serverSeq: j['server_seq'] as int,
      dirty: false,
    );

IdentifierRow identifierFromJson(Map<String, dynamic> j) => IdentifierRow(
      id: j['id'] as String,
      productId: j['product_id'] as String,
      type: j['type'] as String,
      value: j['value'] as String,
      store: j['store'] as String,
      createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(j['updated_at'] as String).toUtc(),
      deleted: j['deleted'] as bool,
      serverSeq: j['server_seq'] as int,
      dirty: false,
    );
