/// Server URL and token read from the web UI's "Connect phone" QR code.
class ConnectCode {
  const ConnectCode(this.url, this.token);
  final String url;
  final String token;
}

/// Parses `shoppingbuddy://connect?url=…&token=…` (docs/sync.md, "Connecting a device").
/// Returns null for any other QR code.
ConnectCode? parseConnectCode(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.scheme != 'shoppingbuddy' || uri.host != 'connect') return null;
  final url = uri.queryParameters['url']?.trim() ?? '';
  final token = uri.queryParameters['token']?.trim() ?? '';
  final server = Uri.tryParse(url);
  if (token.isEmpty || server == null || !server.hasAuthority || !(server.scheme == 'http' || server.scheme == 'https')) {
    return null;
  }
  return ConnectCode(url, token);
}
