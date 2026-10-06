import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shopping_buddy/src/domain/identifiers.dart';
import 'package:shopping_buddy/src/product_info.dart';

void main() {
  group('parseOpenFoodFacts', () {
    test('prefers the German name and takes the first brand', () {
      final info = parseOpenFoodFacts(
        '{"status":1,"product":{"product_name":"Surprise","product_name_de":"Überraschung","brands":"Kinder, Ferrero"}}',
      )!;
      expect(info.name, 'Überraschung');
      expect(info.brand, 'Kinder');
    });

    test('falls back to the main name; brand is optional', () {
      final info = parseOpenFoodFacts('{"status":1,"product":{"product_name":" Milk ","product_name_de":""}}')!;
      expect(info.name, 'Milk');
      expect(info.brand, isNull);
    });

    test('not found or nameless gives null', () {
      expect(parseOpenFoodFacts('{"status":0,"status_verbose":"product not found"}'), isNull);
      expect(parseOpenFoodFacts('{"status":1,"product":{"brands":"X"}}'), isNull);
      expect(parseOpenFoodFacts('[]'), isNull);
    });
  });

  group('OpenFoodFactsLookup', () {
    test('asks for the short GTIN form with a User-Agent', () async {
      late http.Request sent;
      final lookup = OpenFoodFactsLookup(
        client: MockClient((request) async {
          sent = request;
          return http.Response.bytes(utf8.encode('{"status":1,"product":{"product_name":"Überraschung"}}'), 200);
        }),
      );
      final info = await lookup.lookup(normalizeGtin('40084107').value);
      expect(sent.url.path, '/api/v2/product/40084107');
      expect(sent.headers['User-Agent'], startsWith('shoppingBuddy/'));
      expect(info!.name, 'Überraschung');
    });

    test('HTTP errors, network errors and timeouts give null', () async {
      final gtin = normalizeGtin('40084107').value;
      expect(await OpenFoodFactsLookup(client: MockClient((_) async => http.Response('', 404))).lookup(gtin), isNull);
      expect(
        await OpenFoodFactsLookup(client: MockClient((_) => throw http.ClientException('offline'))).lookup(gtin),
        isNull,
      );
      expect(
        await OpenFoodFactsLookup(client: MockClient((_) async => http.Response('not json', 200))).lookup(gtin),
        isNull,
      );
      final slow = OpenFoodFactsLookup(
        client: MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 10),
      );
      expect(await slow.lookup(gtin), isNull);
    });
  });
}
