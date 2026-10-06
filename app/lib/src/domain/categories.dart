/// Category rules. Must stay identical to server/app/categories.py (see docs/sync.md).
library;

const localCategory = 'local';
const _maxLength = 100;
final _domain = RegExp(r'^[\p{L}\p{M}\p{N}_-]+(\.[\p{L}\p{M}\p{N}_-]+)*$', unicode: true);

/// "local" for things bought in a shop, otherwise the website domain:
/// "https://www.Lieferando.de/menu/x" → "lieferando.de".
String normalizeCategory(String raw) {
  var text = raw.trim().toLowerCase();
  if (text.contains('://')) {
    text = Uri.tryParse(text)?.host ?? '';
  } else {
    text = text.split('/').first.split(':').first;
  }
  if (text.startsWith('www.')) text = text.substring(4);
  if (text.isEmpty || text.length > _maxLength || !_domain.hasMatch(text)) {
    throw const FormatException("category must be 'local' or a website domain like lieferando.de");
  }
  return text;
}
