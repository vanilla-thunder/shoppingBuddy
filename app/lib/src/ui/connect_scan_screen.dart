import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../sync/connect_code.dart';

/// Scans the web UI's "Connect phone" QR code and returns it as a [ConnectCode].
class ConnectScanScreen extends StatefulWidget {
  const ConnectScanScreen({super.key});

  @override
  State<ConnectScanScreen> createState() => _ConnectScanScreenState();
}

class _ConnectScanScreenState extends State<ConnectScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  bool _wrongCode = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    final code = parseConnectCode(raw);
    if (code == null) {
      if (!_wrongCode) setState(() => _wrongCode = true);
      return;
    }
    _done = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan connect code')),
      body: Column(
        children: [
          Expanded(child: MobileScanner(controller: _controller, onDetect: _onDetect)),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              _wrongCode
                  ? 'This is not a shoppingBuddy connect code.'
                  : 'In the web UI, open “Connect phone” and scan the QR code shown there.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
