import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../data/repository.dart';
import 'sync_api.dart';
import 'sync_engine.dart';

/// Server settings, sync status and the automatic triggers from docs/sync.md ("Recommended
/// client loop"): app start, app resume, a few seconds after a local edit, and pull-to-refresh.
/// After a failure it retries every minute while the app is in the foreground. There is no
/// sync while the app is closed.
class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController._(this._repo, this._client, this._url, this._token)
      : _engine = SyncEngine(_repo.db);

  static const urlKey = 'sync_url';
  static const tokenKey = 'sync_token';
  static const editDelay = Duration(seconds: 3);
  static const retryDelay = Duration(minutes: 1);

  final ProductRepository _repo;
  final http.Client? _client;
  final SyncEngine _engine;
  String? _url;
  String? _token;

  static Future<SyncController> load(ProductRepository repo, {http.Client? client}) async =>
      SyncController._(repo, client, await repo.getSetting(urlKey), await repo.getSetting(tokenKey));

  String get url => _url ?? '';
  String get token => _token ?? '';
  bool get configured => url.isNotEmpty && token.isNotEmpty;

  bool _running = false;
  bool get running => _running;
  String? _error;
  String? get error => _error;
  DateTime? _lastSuccess;
  DateTime? get lastSuccess => _lastSuccess;
  SyncReport? _lastReport;
  SyncReport? get lastReport => _lastReport;

  /// Rows changed on this device and not yet pushed.
  Stream<int> get unsynced => _repo.watchUnsyncedCount();

  Future<void>? _current;
  bool _again = false;
  Timer? _editTimer;
  Timer? _retryTimer;
  StreamSubscription<int>? _unsyncedSub;
  int _lastUnsynced = 0;
  bool _started = false;

  /// Starts the automatic triggers. Not called in widget tests, which have no use for timers.
  void start() {
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _unsyncedSub = unsynced.listen((count) {
      // Only new local edits schedule a sync; a count that drops is a sync finishing.
      if (count > _lastUnsynced) {
        _editTimer?.cancel();
        _editTimer = Timer(editDelay, syncNow);
      }
      _lastUnsynced = count;
    });
    syncNow();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      syncNow();
    } else if (state == AppLifecycleState.paused) {
      _retryTimer?.cancel();
    }
  }

  /// Saves the server settings and syncs. A different server starts the pull from scratch.
  Future<void> configure(String url, String token) async {
    url = url.trim();
    token = token.trim();
    if (url != this.url) await _repo.setSetting(SyncEngine.lastSeqKey, null);
    await _repo.setSetting(urlKey, url.isEmpty ? null : url);
    await _repo.setSetting(tokenKey, token.isEmpty ? null : token);
    _url = url;
    _token = token;
    _error = null;
    notifyListeners();
    await syncNow();
  }

  /// Runs a sync, or, if one is running, another one right after it (so edits made during
  /// a sync are not left waiting). Never throws; failures end up in [error].
  Future<void> syncNow() {
    if (!configured) return Future.value();
    if (_current != null) {
      _again = true;
      return _current!;
    }
    return _current = _loop().whenComplete(() => _current = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _runOnce();
    } while (_again);
  }

  Future<void> _runOnce() async {
    _retryTimer?.cancel();
    _running = true;
    notifyListeners();
    try {
      final api = SyncApi(baseUrl: url, token: token, client: _client);
      _lastReport = await _engine.run(api);
      _lastSuccess = DateTime.now();
      _error = null;
    } on SyncException catch (e) {
      _error = e.message;
    } on Object catch (e) {
      _error = 'Sync failed: $e';
    } finally {
      _running = false;
      if (_error != null && _started) _retryTimer = Timer(retryDelay, syncNow);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editTimer?.cancel();
    _retryTimer?.cancel();
    _unsyncedSub?.cancel();
    super.dispose();
  }
}
