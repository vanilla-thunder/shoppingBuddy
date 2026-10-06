import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_scope.dart';
import '../domain/identifiers.dart';
import '../scan.dart';
import 'product_form_screen.dart';
import 'widgets/star_rating.dart';

/// Camera scanner with a result card: the rating of a known product, or an "add" prompt.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.cameraBuilder});

  /// Replaces the camera view (used in tests, where no camera exists).
  final Widget Function(BuildContext context, void Function(String raw, {bool isUpcE}) onCode)? cameraBuilder;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.upcA, BarcodeFormat.upcE],
    detectionSpeed: DetectionSpeed.normal,
  );
  ScanResult? _result;
  String? _lastRaw;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onCode(String raw, {bool isUpcE = false}) async {
    // The camera reports the same code many times a second; only react to a new code, or
    // to the same one again after a pause (e.g. after editing it).
    final now = DateTime.now();
    if (raw == _lastRaw && now.difference(_lastAt) < const Duration(seconds: 3)) return;
    _lastRaw = raw;
    _lastAt = now;
    final result = await resolveScan(AppScope.of(context).repo, raw, isUpcE: isUpcE);
    if (mounted) setState(() => _result = result);
  }

  void _onDetect(BarcodeCapture capture) {
    final barcode = capture.barcodes.firstOrNull;
    final raw = barcode?.rawValue;
    if (raw != null) _onCode(raw, isUpcE: barcode!.format == BarcodeFormat.upcE);
  }

  Future<void> _refresh() async {
    final current = _result;
    final ident = switch (current) {
      ScanFound(:final identifier) || ScanUnknown(:final identifier) => identifier,
      _ => null,
    };
    if (ident == null) return;
    final result = await resolveScan(AppScope.of(context).repo, ident.value);
    if (mounted) setState(() => _result = result);
  }

  Future<void> _openForm({String? productId, String? gtin}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProductFormScreen(productId: productId, initialGtin: gtin),
    ));
    await _refresh();
  }

  Future<void> _typeCode() async {
    final code = await showDialog<String>(context: context, builder: (_) => const _ManualEntryDialog());
    if (code != null && code.trim().isNotEmpty) {
      _lastRaw = null;
      await _onCode(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan'),
        actions: [
          IconButton(tooltip: 'Type barcode', icon: const Icon(Icons.keyboard_outlined), onPressed: _typeCode),
          if (widget.cameraBuilder == null)
            IconButton(
              tooltip: 'Torch',
              icon: const Icon(Icons.flashlight_on_outlined),
              onPressed: _controller.toggleTorch,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ClipRect(
              child: widget.cameraBuilder?.call(context, _onCode) ??
                  MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    errorBuilder: (context, error) => _CameraError(error: error),
                  ),
            ),
          ),
          _ResultPanel(
            result: _result,
            onEdit: (id) => _openForm(productId: id),
            onAdd: (gtin) => _openForm(gtin: gtin),
            onRating: (id, rating) async {
              await AppScope.of(context).repo.setRating(id, rating);
              await _refresh();
            },
          ),
        ],
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result, required this.onEdit, required this.onAdd, required this.onRating});

  final ScanResult? result;
  final void Function(String productId) onEdit;
  final void Function(String gtin) onAdd;
  final void Function(String productId, int? rating) onRating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget content = switch (result) {
      null => Text('Point the camera at a barcode', style: theme.textTheme.bodyLarge),
      ScanFound(:final product, :final identifier) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text(product.row.name, style: theme.textTheme.titleLarge)),
                IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => onEdit(product.id)),
              ],
            ),
            Text(
              [product.row.brand, product.row.category, displayGtin(identifier.value)].nonNulls.join(' · '),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            StarRating(rating: product.row.rating, size: 40, onChanged: (r) => onRating(product.id, r)),
            if (product.row.rating == null)
              Text('Not rated yet — tap a star', style: theme.textTheme.bodySmall),
            if (product.row.notes != null) ...[
              const SizedBox(height: 6),
              Text(product.row.notes!, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ScanUnknown(:final identifier) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Unknown product', style: theme.textTheme.titleLarge),
            Text(displayGtin(identifier.value), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => onAdd(identifier.value),
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            ),
          ],
        ),
      ScanInvalid(:final raw, :final reason) => Text('“$raw”: $reason', style: theme.textTheme.bodyLarge),
    };
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
          child: SizedBox(width: double.infinity, child: content),
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final message = error.errorCode == MobileScannerErrorCode.permissionDenied
        ? 'Camera access was denied. Allow it in the system settings, or type the barcode.'
        : 'Camera unavailable (${error.errorCode.name}). You can still type the barcode.';
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

class _ManualEntryDialog extends StatefulWidget {
  const _ManualEntryDialog();

  @override
  State<_ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<_ManualEntryDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Type barcode'),
      content: TextField(
        controller: _text,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(hintText: 'EAN / GTIN'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('Look up')),
      ],
    );
  }
}
