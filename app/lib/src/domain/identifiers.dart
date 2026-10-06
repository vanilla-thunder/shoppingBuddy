/// Barcode and article-number rules. Must stay identical to server/app/identifiers.py
/// (see docs/sync.md, "Identifier normalization").
library;

enum IdentifierType {
  gtin('gtin'),
  storeArticle('store_article');

  const IdentifierType(this.wire);

  /// Name used in the database and the sync API.
  final String wire;

  static IdentifierType fromWire(String value) =>
      values.firstWhere((t) => t.wire == value, orElse: () => throw FormatException('unknown identifier type $value'));
}

class NormalizedIdentifier {
  const NormalizedIdentifier(this.type, this.value, this.store);

  final IdentifierType type;
  final String value;
  final String store;

  @override
  bool operator ==(Object other) =>
      other is NormalizedIdentifier && other.type == type && other.value == value && other.store == store;

  @override
  int get hashCode => Object.hash(type, value, store);

  @override
  String toString() => type == IdentifierType.gtin ? displayGtin(value) : '$store: $value';
}

const gtinLengths = {8, 12, 13, 14};
final _digits = RegExp(r'^[0-9]+$');

bool gtinCheckDigitOk(String code) {
  final digits = code.split('').map(int.parse).toList();
  final body = digits.sublist(0, digits.length - 1).reversed.toList();
  var total = 0;
  for (var i = 0; i < body.length; i++) {
    total += body[i] * (i.isEven ? 3 : 1);
  }
  return (10 - total % 10) % 10 == digits.last;
}

/// GTINs are zero-padded to 14 digits so UPC-A and its EAN-13 form compare equal;
/// store article numbers are scoped to a casefolded store name.
NormalizedIdentifier normalizeIdentifier(IdentifierType type, String value, [String? store]) {
  value = value.trim();
  store = (store ?? '').trim();
  switch (type) {
    case IdentifierType.gtin:
      if (!_digits.hasMatch(value) || !gtinLengths.contains(value.length)) {
        throw const FormatException('GTIN must be 8, 12, 13 or 14 digits');
      }
      if (!gtinCheckDigitOk(value)) throw const FormatException('GTIN check digit is wrong');
      if (store.isNotEmpty) throw const FormatException('GTIN must not have a store');
      return NormalizedIdentifier(type, value.padLeft(14, '0'), '');
    case IdentifierType.storeArticle:
      if (value.isEmpty) throw const FormatException('article number must not be empty');
      if (store.isEmpty) throw const FormatException('store article number needs a store');
      return NormalizedIdentifier(type, value, store.toLowerCase());
  }
}

NormalizedIdentifier normalizeGtin(String value) => normalizeIdentifier(IdentifierType.gtin, value);

/// Expands an 8-digit UPC-E code (as scanners report it) to its 12-digit UPC-A form.
/// Returns null if the code isn't a valid UPC-E.
String? expandUpcE(String code) {
  if (!_digits.hasMatch(code) || code.length != 8 || (code[0] != '0' && code[0] != '1')) return null;
  final d = code.substring(1, 7);
  final last = d[5];
  final String body;
  switch (last) {
    case '0':
    case '1':
    case '2':
      body = '${d.substring(0, 2)}${last}0000${d.substring(2, 5)}';
    case '3':
      body = '${d.substring(0, 3)}00000${d.substring(3, 5)}';
    case '4':
      body = '${d.substring(0, 4)}00000${d[4]}';
    default:
      body = '${d.substring(0, 5)}0000$last';
  }
  final upcA = '${code[0]}$body${code[7]}';
  return gtinCheckDigitOk(upcA) ? upcA : null;
}

/// Shows a stored 14-digit GTIN in its usual printed length (EAN-8, UPC-A or EAN-13).
String displayGtin(String value) {
  for (final (prefix, length) in const [('000000', 8), ('00', 12), ('0', 13)]) {
    if (value.length == 14 && value.startsWith(prefix)) return value.substring(14 - length);
  }
  return value;
}
