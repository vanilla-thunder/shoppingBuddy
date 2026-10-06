import 'data/repository.dart';
import 'domain/identifiers.dart';

/// What a scanned or typed barcode resolved to.
sealed class ScanResult {
  const ScanResult();
}

class ScanFound extends ScanResult {
  const ScanFound(this.product, this.identifier);
  final Product product;
  final NormalizedIdentifier identifier;
}

class ScanUnknown extends ScanResult {
  const ScanUnknown(this.identifier);
  final NormalizedIdentifier identifier;
}

class ScanInvalid extends ScanResult {
  const ScanInvalid(this.raw, this.reason);
  final String raw;
  final String reason;
}

/// Normalizes [raw] (expanding UPC-E first when the scanner says so) and looks it up locally.
Future<ScanResult> resolveScan(ProductRepository repo, String raw, {bool isUpcE = false}) async {
  final code = raw.trim();
  final candidate = isUpcE ? expandUpcE(code) : code;
  if (candidate == null) return ScanInvalid(code, 'not a valid UPC-E code');
  final NormalizedIdentifier ident;
  try {
    ident = normalizeGtin(candidate);
  } on FormatException catch (e) {
    return ScanInvalid(code, e.message);
  }
  final product = await repo.lookup(ident);
  return product == null ? ScanUnknown(ident) : ScanFound(product, ident);
}
