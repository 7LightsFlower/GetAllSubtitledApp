// internal_auth_service.dart
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:html' as html;
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
  static const String _emailKey = 'user_email';
  static const String _manualTokenKey = 'manual_auth_token';

  // ─── OAuth endpoints ──────────────────────────────────────────────

  static String get _tokenEndpoint {
    if (kIsWeb) {
      return '$authBaseUrl/dex/token';
    } else {
      return '$dexIssuer/token';
    }
  }

  static String get _userInfoEndpoint {
    if (kIsWeb) {
      return '$authBaseUrl/dex/userinfo';
    } else {
      return '$dexIssuer/userinfo';
    }
  }

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

  // ─── Manual Token Management ──────────────────────────────────────

  static Future<void> setManualToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_manualTokenKey, token);
    // Also store as access token for compatibility
    await prefs.setString(_accessTokenKey, token);
    if (kDebugMode) print('✅ Manual token set');
  }

  static Future<void> clearManualToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_manualTokenKey);
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_expiryKey);
    await prefs.remove(_emailKey);
    if (kDebugMode) print('✅ Manual token cleared');
  }

  static Future<String?> getManualToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_manualTokenKey);
  }

  // ─── OAuth Login (popup) ──────────────────────────────────────────

  static Future<bool> loginWithOAuth() async {
    try {
      final verifier = _generateCodeVerifier();
      if (kDebugMode) print('🔑 Generated verifier: $verifier');

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

      String redirectUrl;

      if (kIsWeb) {
        final completer = Completer<String>();
        final popup = html.window.open(
          authUrl.toString(),
          'oauth',
          'width=600,height=700,scrollbars=yes',
        );

        Timer.periodic(const Duration(milliseconds: 500), (timer) {
          try {
            final currentUrl = (popup.location as dynamic).href as String;
            if (currentUrl.startsWith(dexRedirectUri)) {
              timer.cancel();
              popup.close();
              if (!completer.isCompleted) {
                completer.complete(currentUrl);
              }
            }
          } catch (_) {
            // Cross‑origin error – will retry
          }
        });

        redirectUrl = await completer.future.timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw Exception('OAuth popup timed out or was closed'),
        );
      } else {
        redirectUrl = await FlutterWebAuth.authenticate(
          url: authUrl.toString(),
          callbackUrlScheme: 'https',
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

      // ─── Exchange code with Basic Auth ──────────────────────────
      final credentials = base64Encode(utf8.encode('$dexClientId:$dexClientSecret'));
      final tokenResponse = await http.post(
        Uri.parse(_tokenEndpoint),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Authorization': 'Basic $credentials',
        },
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': dexRedirectUri,
          'code_verifier': verifier,
        },
      );

      if (tokenResponse.statusCode != 200) {
        if (kDebugMode) {
          print('❌ Token exchange failed: ${tokenResponse.statusCode}');
          print('❌ Body: ${tokenResponse.body}');
        }
        return false;
      }

      final data = jsonDecode(tokenResponse.body);
      final accessToken = data['access_token'];
      final refreshToken = data['refresh_token'];
      final expiresIn = data['expires_in'] ?? 3600;

      if (accessToken == null) {
        if (kDebugMode) print('❌ No access token in response');
        return false;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accessTokenKey, accessToken);
      if (refreshToken != null) {
        await prefs.setString(_refreshTokenKey, refreshToken);
      }
      final expiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
      await prefs.setString(_expiryKey, expiry.toIso8601String());

      // Cache email
      await getUserEmail();

      if (kDebugMode) print('✅ OAuth login successful, token stored');
      return true;
    } catch (e) {
      if (kDebugMode) print('❌ OAuth login error: $e');
      return false;
    }
  }

  // ─── Handle OAuth callback (for redirect flow) ────────────────────

  static Future<bool> handleOAuthCallback() async {
    if (!kIsWeb) return false;

    final uri = Uri.parse(html.window.location.href);
    final code = uri.queryParameters['code'];
    if (code == null) return false;

    final verifier = html.window.sessionStorage['dex_verifier'];
    if (verifier == null) {
      if (kDebugMode) print('No verifier found in sessionStorage');
      return false;
    }

    html.window.history.replaceState({}, '', uri.replace(queryParameters: {}).toString());

    final credentials = base64Encode(utf8.encode('$dexClientId:$dexClientSecret'));
    final tokenResponse = await http.post(
      Uri.parse(_tokenEndpoint),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': 'Basic $credentials',
      },
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': dexRedirectUri,
        'code_verifier': verifier,
      },
    );

    if (tokenResponse.statusCode != 200) {
      if (kDebugMode) print('Token exchange failed: ${tokenResponse.body}');
      return false;
    }

    final data = jsonDecode(tokenResponse.body);
    final accessToken = data['access_token'];
    final refreshToken = data['refresh_token'];
    final expiresIn = data['expires_in'] ?? 3600;

    if (accessToken == null) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, accessToken);
    if (refreshToken != null) {
      await prefs.setString(_refreshTokenKey, refreshToken);
    }
    final expiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
    await prefs.setString(_expiryKey, expiry.toIso8601String());

    html.window.sessionStorage.remove('dex_verifier');
    await getUserEmail();
    if (kDebugMode) print('✅ OAuth login successful (redirect flow)');
    return true;
  }

  // ─── Redirect to Dex (full‑page) ───────────────────────────────────

  static Future<void> redirectToDex() async {
    if (!kIsWeb) {
      throw Exception('Redirect login is only supported on web.');
    }
    final verifier = _generateCodeVerifier();
    html.window.sessionStorage['dex_verifier'] = verifier;
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

    html.window.location.href = authUrl.toString();
  }

  // ─── Token storage and refresh ────────────────────────────────────

  static Future<String?> getValidAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Check for manual token first
    final manualToken = prefs.getString(_manualTokenKey);
    if (manualToken != null && manualToken.isNotEmpty) {
      if (kDebugMode) print('🔑 Using manual token');
      return manualToken;
    }
    
    final accessToken = prefs.getString(_accessTokenKey);
    final refreshToken = prefs.getString(_refreshTokenKey);
    final expiryStr = prefs.getString(_expiryKey);

    if (accessToken == null) {
      if (kDebugMode) print('🔍 No access token – returning null');
      return null;
    }

    if (expiryStr != null) {
      final expiry = DateTime.parse(expiryStr);
      final now = DateTime.now().toUtc();
      if (now.isBefore(expiry)) {
        return accessToken;
      }
    }

    // Token expired – try to refresh
    if (refreshToken != null) {
      if (kDebugMode) print('🔄 Token expired – attempting refresh...');
      try {
        final credentials = base64Encode(utf8.encode('$dexClientId:$dexClientSecret'));
        final response = await http.post(
          Uri.parse(_tokenEndpoint),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Authorization': 'Basic $credentials',
          },
          body: {
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
            final newExpiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
            await prefs.setString(_expiryKey, newExpiry.toIso8601String());
            if (kDebugMode) print('✅ Refresh successful – returning new token');
            return newAccessToken;
          }
        } else {
          if (kDebugMode) print('❌ Refresh failed: ${response.statusCode}');
        }
      } catch (e) {
        if (kDebugMode) print('❌ Refresh error: $e');
      }
    }

    if (kDebugMode) print('❌ Token refresh failed – clearing tokens');
    await clearTokens();
    return null;
  }

  static Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_expiryKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_manualTokenKey);
  }

  // ─── Simple token fetcher (for cookie-based endpoints) ───────────

  static Future<String?> getToken() async {
    // First check for manual token
    final prefs = await SharedPreferences.getInstance();
    final manualToken = prefs.getString(_manualTokenKey);
    if (manualToken != null && manualToken.isNotEmpty) {
      if (kDebugMode) print('🔑 getToken: Using manual token');
      return manualToken;
    }

    // If no manual token, try to get from server
    try {
      if (kIsWeb) {
        final completer = Completer<String?>();
        final request = html.HttpRequest();
        request.open('GET', '$authBaseUrl/gettoken', async: true);
        request.withCredentials = true;
        request.onLoad.listen((_) {
          if (request.status == 200) {
            completer.complete(request.responseText?.trim());
          } else {
            completer.completeError('HTTP ${request.status}');
          }
        });
        request.onError.listen((e) => completer.completeError(e));
        request.send();
        final token = await completer.future;
        if (token is String && token.isNotEmpty) return token;
        return null;
      } else {
        final response = await http.get(Uri.parse('$internalServerUrl/gettoken'));
        if (response.statusCode == 200) {
          final token = response.body.trim();
          if (token.isNotEmpty) return token;
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error fetching token: $e');
      return null;
    }
  }

  // ─── Redirect to login (for 401/403 responses) ──────────────────

  static void redirectToLogin() {
    if (!kIsWeb) return;
    html.window.location.href = '$internalServerUrl/login';
  }

  // ─── User email ────────────────────────────────────────────────────

  static Future<String?> getUserEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_emailKey);
    if (cached != null && cached.isNotEmpty) {
      if (kDebugMode) print('📧 Using cached email: $cached');
      return cached;
    }

    final token = await getValidAccessToken();
    if (token == null) {
      if (kDebugMode) print('❌ No valid token to fetch userinfo');
      return null;
    }

    try {
      final response = await http.get(
        Uri.parse(_userInfoEndpoint),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final email = data['email'] as String?;
        if (email != null && email.isNotEmpty) {
          await prefs.setString(_emailKey, email);
          if (kDebugMode) print('📧 Fetched and cached email: $email');
          return email;
        }
      } else {
        if (kDebugMode) print('❌ Userinfo failed: ${response.statusCode}');
      }
    } catch (e) {
      if (kDebugMode) print('❌ Error fetching userinfo: $e');
    }
    return null;
  }

  // ─── Check authentication ─────────────────────────────────────────

  static Future<bool> isAuthenticated() async {
    final token = await getValidAccessToken();
    return token != null;
  }
}