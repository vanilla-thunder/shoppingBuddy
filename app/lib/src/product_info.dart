import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'domain/identifiers.dart';

/// Name and brand suggested for an unknown barcode. Only used to prefill the add form.
class ProductInfo {
  const ProductInfo({required this.name, this.brand});
  final String name;
  final String? brand;
}

/// Looks up product data for a GTIN. Returns null when nothing is found or the lookup fails
/// (offline, timeout, bad response): the form then simply stays empty.
abstract interface class ProductInfoLookup {
  Future<ProductInfo?> lookup(String gtin);
}

class OpenFoodFactsLookup implements ProductInfoLookup {
  OpenFoodFactsLookup({http.Client? client, this.timeout = const Duration(seconds: 5)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  // Open Food Facts asks every app to identify itself.
  static const _userAgent = 'shoppingBuddy/1.0 (https://github.com/vanilla-thunder/shoppingBuddy)';

  @override
  Future<ProductInfo?> lookup(String gtin) async {
    final uri = Uri.https('world.openfoodfacts.org', '/api/v2/product/${displayGtin(gtin)}', {
      'fields': 'product_name,product_name_de,brands',
    });
    try {
      final response = await _client.get(uri, headers: {'User-Agent': _userAgent}).timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseOpenFoodFacts(utf8.decode(response.bodyBytes));
    } on Exception {
      return null;
    }
  }
}

/// Picks the German name if there is one, and the first of the comma-separated brands.
ProductInfo? parseOpenFoodFacts(String body) {
  final json = jsonDecode(body);
  if (json is! Map || json['status'] != 1 || json['product'] is! Map) return null;
  final product = json['product'] as Map;
  String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final name = text(product['product_name_de']) ?? text(product['product_name']);
  if (name == null) return null;
  final brand = text((text(product['brands']) ?? '').split(',').first);
  return ProductInfo(name: name, brand: brand);
}
