import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../sync/connect_code.dart';
import '../sync/sync_controller.dart';
import 'connect_scan_screen.dart';

/// Server URL and token, sync status, and a manual "Sync now".
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _showToken = false;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final sync = AppScope.of(context).sync;
    _url.text = sync.url;
    _token.text = sync.token;
    _loaded = true;
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  String? _validateUrl(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return 'Enter a URL such as https://buddy.example.org';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await AppScope.of(context).sync.configure(_url.text, _token.text);
  }

  Future<void> _scanConnectCode() async {
    final code = await Navigator.of(context).push<ConnectCode>(
      MaterialPageRoute(builder: (_) => const ConnectScanScreen()),
    );
    if (code == null || !mounted) return;
    _url.text = code.url;
    _token.text = code.token;
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListenableBuilder(listenable: sync, builder: (context, _) => _Status(sync: sync)),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              onPressed: _scanConnectCode,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Scan QR code'),
            ),
            const SizedBox(height: 8),
            Text(
              'Shown in the web UI under “Connect phone”. Or enter the details by hand:',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Server URL'),
              validator: _validateUrl,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _token,
              obscureText: !_showToken,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API token',
                suffixIcon: IconButton(
                  tooltip: _showToken ? 'Hide token' : 'Show token',
                  icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => setState(() => _showToken = !_showToken),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save and sync')),
          ],
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.sync});

  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = sync.lastReport;
    final last = sync.lastSuccess;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StreamBuilder<int>(
              stream: sync.unsynced,
              builder: (context, snapshot) {
                final count = snapshot.data ?? 0;
                return Text(
                  count == 0 ? 'All changes synced' : '$count unsynced ${count == 1 ? 'change' : 'changes'}',
                  style: theme.textTheme.titleMedium,
                );
              },
            ),
            const SizedBox(height: 4),
            if (!sync.configured)
              const Text('Enter the server URL and token to sync.')
            else if (sync.running)
              const Text('Syncing…')
            else if (sync.error != null)
              Text(sync.error!, style: TextStyle(color: theme.colorScheme.error))
            else if (last != null)
              Text('Last sync ${TimeOfDay.fromDateTime(last).format(context)}'
                  '${report == null ? '' : ': sent ${report.pushed}, received ${report.pulled}'}'
                  '${report == null || report.rejected == 0 ? '' : ', ${report.rejected} refused'}'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: sync.configured && !sync.running ? sync.syncNow : null,
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
            ),
          ],
        ),
      ),
    );
  }
}
