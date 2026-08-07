// internal_auth_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html if (dart.library.html) '';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_web_auth/flutter_web_auth.dart';
import 'package:asr_live_translator/constants.dart';
import 'package:crypto/crypto.dart';

class InternalAuthService {
  static const String _accessTokenKey = 'internal_access_token';
  static const String _refreshTokenKey = 'internal_refresh_token';
  static const String _expiryKey = 'internal_token_expiry';

  // ─── Store the last verifier for manual exchange ──────────
  static String? _lastVerifier;

  // ─── PKCE helpers ──────────────────────────────────────────────
  static String _generateCodeVerifier() {
    final random = Random.secure();
    var bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  // ─── OAuth login via Dex ───────────────────────────────────────
  static Future<bool> loginWithOAuth() async {
    try {
      final verifier = _generateCodeVerifier();
      _lastVerifier = verifier; // store for manual exchange
      final challenge = _generateCodeChallenge(verifier);

      final authUrl = Uri.parse('$dexIssuer/auth').replace(queryParameters: {
        'client_id': dexClientId,
        'redirect_uri': dexRedirectUri,
        'response_type': 'code',
        'scope': dexScopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': 'random-state-${DateTime.now().millisecondsSinceEpoch}',
      });

      String? redirectUrl;

      if (kIsWeb) {
        // ─── Web: manual popup with polling ──────────────────────
        final completer = Completer<String>();
        final popup = html.window.open(
          authUrl.toString(),
          'oauth',
          'width=600,height=700,scrollbars=yes',
        );

        // Poll the popup's URL every 500ms
        Timer.periodic(const Duration(milliseconds: 500), (timer) {
          try {
            // Cast to dynamic to avoid static analysis issues
            final currentUrl = (popup.location as dynamic).href as String;
            if (currentUrl.startsWith(dexRedirectUri)) {
              timer.cancel();
              popup.close();
              if (!completer.isCompleted) {
                completer.complete(currentUrl);
              }
            }
          } catch (_) {
            // Cross-origin or temporary error – ignore, will retry
          }
        });

        // Fallback: timeout after 2 minutes
        redirectUrl = await completer.future.timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw Exception('OAuth popup timed out or was closed'),
        );
      } else {
        // ─── Mobile (Android/iOS): use native plugin ─────────────
        // ⚠️ For mobile you need a custom scheme (e.g., 'myapp://oauth')
        // and must add it to the allowed redirect URIs on the server.
        redirectUrl = await FlutterWebAuth.authenticate(
          url: authUrl.toString(),
          callbackUrlScheme: 'https', // Replace with your custom scheme
        );
      }

      if (kDebugMode) print('🔐 Full redirect URL: $redirectUrl');
      final uri = Uri.parse(redirectUrl);
      final code = uri.queryParameters['code'];
      if (kDebugMode) print('🔑 Extracted code: $code');

      if (code == null) {
        if (kDebugMode) print('No code in redirect');
        return false;
      }

      // ─── Exchange code for tokens ──────────────────────────────
      final tokenResponse = await http.post(
        Uri.parse('$dexIssuer/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': dexClientId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': dexRedirectUri,
          'code_verifier': verifier,
        },
      );

      if (tokenResponse.statusCode != 200) {
        if (kDebugMode) {
          print('Token exchange failed: ${tokenResponse.statusCode}');
          print('Response body: ${tokenResponse.body}');
        }
        return false;
      }

      final data = jsonDecode(tokenResponse.body);
      final accessToken = data['access_token'];
      final refreshToken = data['refresh_token'];
      final expiresIn = data['expires_in'] ?? 3600;

      if (accessToken == null) {
        if (kDebugMode) print('No access token in response');
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accessTokenKey, accessToken);
      if (refreshToken != null) {
        await prefs.setString(_refreshTokenKey, refreshToken);
      }
      final expiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
      await prefs.setString(_expiryKey, expiry.toIso8601String());

      if (kDebugMode) print('✅ OAuth login successful, token stored');
      return true;
    } catch (e) {
      if (kDebugMode) print('OAuth login error: $e');
      return false;
    }
  }

  // ─── Manual exchange (debug workaround) ──────────────────────
  static Future<bool> exchangeCodeManually(String code) async {
    if (_lastVerifier == null) {
      if (kDebugMode) print('No verifier available. Please run OAuth login first.');
      return false;
    }
    try {
      final tokenResponse = await http.post(
        Uri.parse('$dexIssuer/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': dexClientId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': dexRedirectUri,
          'code_verifier': _lastVerifier!,
        },
      );

      if (tokenResponse.statusCode != 200) {
        if (kDebugMode) {
          print('Manual token exchange failed: ${tokenResponse.statusCode}');
          print('Body: ${tokenResponse.body}');
        }
        return false;
      }

      final data = jsonDecode(tokenResponse.body);
      final accessToken = data['access_token'];
      final refreshToken = data['refresh_token'];
      final expiresIn = data['expires_in'] ?? 3600;

      if (accessToken == null) {
        if (kDebugMode) print('No access token in manual response');
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accessTokenKey, accessToken);
      if (refreshToken != null) {
        await prefs.setString(_refreshTokenKey, refreshToken);
      }
      final expiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
      await prefs.setString(_expiryKey, expiry.toIso8601String());

      if (kDebugMode) print('✅ Manual token exchange successful');
      return true;
    } catch (e) {
      if (kDebugMode) print('Manual exchange error: $e');
      return false;
    }
  }

  // ─── Get valid access token (refresh if needed) ──────────────
  static Future<String?> getValidAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString(_accessTokenKey);
    final refreshToken = prefs.getString(_refreshTokenKey);
    final expiryStr = prefs.getString(_expiryKey);

    if (accessToken == null) return null;

    // Check expiry
    if (expiryStr != null) {
      final expiry = DateTime.parse(expiryStr);
      if (DateTime.now().toUtc().isBefore(expiry)) {
        return accessToken;
      }
    }

    // Token expired – try to refresh
    if (refreshToken != null) {
      try {
        final response = await http.post(
          Uri.parse('$dexIssuer/token'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'client_id': dexClientId,
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
          },
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final newAccessToken = data['access_token'];
          final newRefreshToken = data['refresh_token'];
          final expiresIn = data['expires_in'] ?? 3600;
          if (newAccessToken != null) {
            await prefs.setString(_accessTokenKey, newAccessToken);
            if (newRefreshToken != null) {
              await prefs.setString(_refreshTokenKey, newRefreshToken);
            }
            final expiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
            await prefs.setString(_expiryKey, expiry.toIso8601String());
            return newAccessToken;
          }
        }
      } catch (e) {
        if (kDebugMode) print('Refresh failed: $e');
      }
    }

    // If we get here, refresh failed or no refresh token – clear everything
    await clearTokens();
    return null;
  }

  static Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_expiryKey);
  }

  static Future<String?> getToken() async => getValidAccessToken();
  static Future<void> clearToken() async => clearTokens();
}
