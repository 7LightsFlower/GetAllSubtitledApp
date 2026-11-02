// session_share_card.dart
//
// QR code + link for a running live session, so the audience can follow
// it on their phones:  <server>/shorten/webapi/<permanent name>
//
//   ┌──────────────────────────────────────────────────────────┐
//   │ ▓▓▓▓▓▓  Follow this session                              │
//   │ ▓ QR ▓  https://lt2srv…/shorten/webapi/abc123            │
//   │ ▓▓▓▓▓▓  [view2] [Copy link] [Share] [QR as PNG]          │
//   └──────────────────────────────────────────────────────────┘
//
// Tap the QR code for a full-screen version (for a projector).

import 'dart:js_interop';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:web/web.dart' as web;

class SessionShareCard extends StatelessWidget {
  const SessionShareCard({
    super.key,
    required this.url,
    this.title = 'Follow this session',
    this.fileBaseName = 'live_session',
  });

  final String url;
  final String title;
  final String fileBaseName;

  bool _narrow(BuildContext c) => MediaQuery.sizeOf(c).width < 600;

  void _snack(BuildContext c, String text) =>
      ScaffoldMessenger.of(c).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );

  void _open() => web.window.open(url, '_blank');

  Future<void> _copy(BuildContext c) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (c.mounted) _snack(c, 'Link copied');
  }

  /// The browser's own share sheet (phones, Edge, Safari, Chrome on
  /// Windows/Android); falls back to copying the link.
  Future<void> _share(BuildContext c) async {
    try {
      final data = web.ShareData(title: title, text: title, url: url);
      await web.window.navigator.share(data).toDart;
      return;
    } catch (e) {
      // AbortError = the user closed the sheet: nothing to do.
      if (e.toString().contains('AbortError')) return;
    }
    if (c.mounted) await _copy(c);
  }

  Future<void> _downloadPng(BuildContext c) async {
    try {
      final painter = QrPainter(
        data: url,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        gapless: true,
        eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square, color: Colors.black),
        dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square, color: Colors.black),
      );
      final data = await painter.toImageData(1024, format: ui.ImageByteFormat.png);
      if (data == null) throw Exception('no image');
      final bytes = data.buffer.asUint8List();
      final blob = web.Blob(
        <JSAny>[bytes.toJS].toJS,
        web.BlobPropertyBag(type: 'image/png'),
      );
      final href = web.URL.createObjectURL(blob);
      (web.HTMLAnchorElement()
            ..href = href
            ..download = '${fileBaseName}_qr.png')
          .click();
      web.URL.revokeObjectURL(href);
    } catch (e) {
      if (c.mounted) _snack(c, 'Could not create the QR image: $e');
    }
  }

  void _fullScreen(BuildContext c) {
    showDialog<void>(
      context: c,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final side = (size.shortestSide * 0.75).clamp(200.0, 900.0);
        return Dialog(
          backgroundColor: Colors.white,
          insetPadding: const EdgeInsets.all(16),
          child: InkWell(
            onTap: () => Navigator.pop(ctx),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  QrImageView(
                    data: url,
                    size: side,
                    backgroundColor: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(url,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Tap to close',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = _narrow(context);
    final qrSide = narrow ? 110.0 : 132.0;

    final qr = Tooltip(
      message: 'Show large (for a projector)',
      child: InkWell(
        onTap: () => _fullScreen(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: QrImageView(
            data: url,
            size: qrSide,
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
          ),
        ),
      ),
    );

    final buttons = Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        FilledButton.icon(
          onPressed: _open,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('view2'),
        ),
        OutlinedButton.icon(
          onPressed: () => _copy(context),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy link'),
        ),
        OutlinedButton.icon(
          onPressed: () => _share(context),
          icon: const Icon(Icons.share, size: 18),
          label: const Text('Share'),
        ),
        OutlinedButton.icon(
          onPressed: () => _downloadPng(context),
          icon: const Icon(Icons.qr_code_2, size: 18),
          label: const Text('QR as PNG'),
        ),
      ],
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.qr_code, size: 18, color: Colors.blue.shade700),
          const SizedBox(width: 6),
          Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ]),
        const SizedBox(height: 4),
        SelectableText(
          url,
          style: TextStyle(fontSize: 13, color: Colors.blue.shade800),
        ),
        const SizedBox(height: 10),
        buttons,
      ],
    );

    return Card(
      margin: EdgeInsets.zero,
      color: Colors.blue.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.blue.shade100),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Center(child: qr), const SizedBox(height: 10), info],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [qr, const SizedBox(width: 16), Expanded(child: info)],
              ),
      ),
    );
  }
}
