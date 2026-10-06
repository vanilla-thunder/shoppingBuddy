import 'package:flutter_test/flutter_test.dart';
import 'package:shopping_buddy/src/domain/categories.dart';
import 'package:shopping_buddy/src/domain/identifiers.dart';

// Same vectors as server/tests/test_identifiers.py and test_categories.py.
const ean13 = '4006381333931';
const upcA = '036000291452';
const ean8 = '96385074';

void main() {
  group('GTIN', () {
    for (final code in [ean13, upcA, ean8, '0$ean13']) {
      test('$code is padded to 14 digits', () {
        final n = normalizeIdentifier(IdentifierType.gtin, '  $code ');
        expect(n.value, code.padLeft(14, '0'));
        expect(n.store, '');
      });
    }

    test('UPC-A equals its EAN-13 form', () {
      expect(normalizeGtin(upcA), normalizeGtin('0$upcA'));
    });

    for (final code in ['4006381333932', '12345', '40063813339a1', '４００６３８１３３３９３１']) {
      test('$code is rejected', () {
        expect(() => normalizeGtin(code), throwsFormatException);
      });
    }

    test('display uses printed length', () {
      expect(displayGtin(normalizeGtin(ean13).value), ean13);
      expect(displayGtin(normalizeGtin(upcA).value), upcA);
      expect(displayGtin(normalizeGtin(ean8).value), ean8);
    });

    test('UPC-E expands to UPC-A', () {
      expect(expandUpcE('04252614'), '042100005264');
      expect(expandUpcE('01234565'), '012345000065');
      expect(expandUpcE('04252615'), isNull); // wrong check digit
      expect(expandUpcE(ean8), isNull);
    });
  });

  test('store article needs a store and lowercases it', () {
    final n = normalizeIdentifier(IdentifierType.storeArticle, '12345', ' ALDI ');
    expect((n.value, n.store), ('12345', 'aldi'));
    expect(normalizeIdentifier(IdentifierType.storeArticle, '1', 'Straße').store, 'straße');
    expect(() => normalizeIdentifier(IdentifierType.storeArticle, '12345', ''), throwsFormatException);
  });

  group('category', () {
    const cases = {
      'local': 'local',
      '  Local ': 'local',
      'lieferando.de': 'lieferando.de',
      'https://www.lieferando.de/speisekarte/pizza-luigi': 'lieferando.de',
      'www.Wolt.com/de': 'wolt.com',
      'lieferando.de:443': 'lieferando.de',
      'bäckerei-müller.de': 'bäckerei-müller.de',
    };
    cases.forEach((raw, expected) {
      test('"$raw" → $expected', () => expect(normalizeCategory(raw), expected));
    });

    for (final raw in ['', '   ', 'https://', 'two words', 'a..b', 'x' * 101]) {
      test('"$raw" is rejected', () => expect(() => normalizeCategory(raw), throwsFormatException));
    }
  });
}
