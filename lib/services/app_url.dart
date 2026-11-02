// app_url.dart
//
// Keeps the browser address in line with what is on screen, so every
// page can be bookmarked, shared and reloaded:
//
//   /overview/<email>                      start page (Videos / Live sessions)
//   /video-sessions/<email>                video list
//   /session-detail/<video key>            one video (set by Session Detail)
//   /live-sessions/<email>                 live sessions list
//   /live-sessions/<email>/new             recording a new live session
//   /live-sessions/<email>/<session id>    one finished live session
//
// The email part is informational (whose list it is); the app always
// shows the logged-in user's data.

import 'package:asr_live_translator/services/internal_auth_service.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

class AppUrl {
  AppUrl._();

  static const overview = 'overview';
  static const videos = 'video-sessions';
  static const live = 'live-sessions';

  /// Email inside the KIT token (`<opaque>|<expiry>|<email>`), or ''.
  static Future<String> email() async {
    try {
      final token = await InternalAuthService.getToken() ?? '';
      final parts = token.split('|');
      if (parts.length >= 3 && parts.last.contains('@')) {
        return parts.last.trim();
      }
    } catch (_) {}
    return '';
  }

  /// Show /<section>/<email>[/<id>] in the address bar (no navigation).
  static Future<void> set(String section, [String? id]) async {
    try {
      final mail = await email();
      final path = StringBuffer('/$section');
      if (mail.isNotEmpty) path.write('/${Uri.encodeComponent(mail)}');
      if (id != null && id.isNotEmpty) path.write('/${Uri.encodeComponent(id)}');
      final p = path.toString();
      if (web.window.location.pathname != p) {
        web.window.history.replaceState(null, '', p);
      }
    } catch (e) {
      debugPrint('address bar update failed: $e');
    }
  }

  /// Splits a route like `/live-sessions/a%40b.c/123` into
  /// (section, id). The email segment is skipped. Null if [name] is not
  /// one of our sections.
  static (String, String?)? parse(String name) {
    final segs = Uri.parse(name).pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return null;
    final section = segs.first == 'working' ? overview : segs.first;
    if (section != overview && section != videos && section != live) {
      return null;
    }
    // /<section>/<email>/<id>  — or /<section>/<id> when no email.
    String? id;
    if (segs.length >= 3) {
      id = segs[2];
    } else if (segs.length == 2 && !segs[1].contains('@')) {
      id = segs[1];
    }
    return (section, id);
  }
}
