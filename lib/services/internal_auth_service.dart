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

  static String? _lastVerifier;

  // ─── Helper: token endpoint (proxied on web) ────────────────
  static bool get _useProxy => false; // set to true only if proxy works

  static String get _tokenEndpoint {
    if (kIsWeb && _useProxy) {
      return '/dex/token';
    } else {
      return '$dexIssuer/token';
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

  static Future<bool> loginWithOAuth() async {
    try {
      final verifier = _generateCodeVerifier();
      _lastVerifier = verifier;
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
          callbackUrlScheme: 'https', // For mobile, use a custom scheme
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

      // ─── Exchange code with Basic Auth (proxied on web) ──────
      final credentials = base64Encode(utf8.encode('$dexClientId:$dexClientSecret'));
      if (kDebugMode) {
        print('🔑 Basic Auth length: ${credentials.length}');
        print('🔑 Client ID: $dexClientId');
        print('🔑 Secret (first 10 chars): ${dexClientSecret.substring(0, 10)}...');
        print('🔑 Token endpoint: $_tokenEndpoint');
      }

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

      if (kDebugMode) print('✅ OAuth login successful, token stored');
      return true;
    } catch (e) {
      if (kDebugMode) print('❌ OAuth login error: $e');
      return false;
    }
  }

  // ─── Manual code exchange (debug workaround) ──────────────────────
  static Future<bool> exchangeCodeManually(String code) async {
    if (_lastVerifier == null) {
      if (kDebugMode) print('❌ No verifier available. Please run OAuth login first.');
      return false;
    }
    try {
      final credentials = base64Encode(utf8.encode('$dexClientId:$dexClientSecret'));
      if (kDebugMode) {
        print('🔑 Manual exchange – Basic Auth length: ${credentials.length}');
        print('🔑 Client ID: $dexClientId');
        print('🔑 Secret (first 10 chars): ${dexClientSecret.substring(0, 10)}...');
        print('🔑 Token endpoint: $_tokenEndpoint');
      }

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
          'code_verifier': _lastVerifier!,
        },
      );

      if (tokenResponse.statusCode != 200) {
        if (kDebugMode) {
          print('❌ Manual token exchange failed: ${tokenResponse.statusCode}');
          print('❌ Body: ${tokenResponse.body}');
        }
        return false;
      }

      final data = jsonDecode(tokenResponse.body);
      final accessToken = data['access_token'];
      final refreshToken = data['refresh_token'];
      final expiresIn = data['expires_in'] ?? 3600;

      if (accessToken == null) {
        if (kDebugMode) print('❌ No access token in manual response');
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
      if (kDebugMode) print('❌ Manual exchange error: $e');
      return false;
    }
  }

  // ─── Get valid access token (refresh if needed) ──────────────
  static Future<String?> getValidAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString(_accessTokenKey);
    final refreshToken = prefs.getString(_refreshTokenKey);
    final expiryStr = prefs.getString(_expiryKey);

    if (kDebugMode) {
      print('🔍 getValidAccessToken: accessToken = ${accessToken != null ? "exists (${accessToken.length} chars)" : "null"}');
    }
    if (kDebugMode) {
      print('🔍 getValidAccessToken: refreshToken = ${refreshToken != null ? "exists" : "null"}');
    }
    if (kDebugMode) {
      print('🔍 getValidAccessToken: expiryStr = $expiryStr');
    }

    if (accessToken == null) {
      if (kDebugMode) {
        print('🔍 No access token – returning null');
      }
      return null;
    }

    if (expiryStr != null) {
      final expiry = DateTime.parse(expiryStr);
      final now = DateTime.now().toUtc();
      if (kDebugMode) {
        print('🔍 Token expiry: $expiry, now: $now, isBefore: ${now.isBefore(expiry)}');
      }
      if (now.isBefore(expiry)) {
        if (kDebugMode) {
          print('✅ Token valid – returning it');
        }
        return accessToken;
      }
    } else {
      if (kDebugMode) {
        print('⚠️ No expiry stored – assuming valid');
      }
      return accessToken; // treat as valid if no expiry
    }

    // Token expired – try to refresh
    if (refreshToken != null) {
      if (kDebugMode) {
        print('🔄 Token expired – attempting refresh...');
      }
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
            final expiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));
            await prefs.setString(_expiryKey, expiry.toIso8601String());
            if (kDebugMode) {
              print('✅ Refresh successful – returning new token');
            }
            return newAccessToken;
          }
        } else {
          if (kDebugMode) {
            print('❌ Refresh failed with status ${response.statusCode}: ${response.body}');
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('❌ Refresh error: $e');
        }
      }
    } else {
      if (kDebugMode) {
        print('❌ No refresh token – clearing and returning null');
      }
    }

    if (kDebugMode) {
      print('❌ Token refresh failed or missing – clearing tokens and returning null');
    }
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

  // ─── Redirect to Dex (full‑page) ───────────────────────────────
  static Future<void> redirectToDex() async {
    if (!kIsWeb) {
      throw Exception('Redirect login is only supported on web.');
    }
    final verifier = _generateCodeVerifier();
    // Store verifier in sessionStorage
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

  static Future<bool> handleOAuthCallback() async {
    if (!kIsWeb) return false;

    final uri = Uri.parse(html.window.location.href);
    final code = uri.queryParameters['code'];
    if (code == null) return false;

    // Retrieve verifier from sessionStorage
    final verifier = html.window.sessionStorage['dex_verifier'];
    if (verifier == null) {
      if (kDebugMode) {
        print('No verifier found in sessionStorage');
      }
      return false;
    }

    // Clear the code from URL
    html.window.history.replaceState({}, '', uri.replace(queryParameters: {}).toString());

    // Exchange code for tokens (with Basic Auth)
    final credentials = base64Encode(utf8.encode('$dexClientId:$dexClientSecret'));
    if (kDebugMode) {
      print('🔑 handleOAuthCallback: token endpoint = $_tokenEndpoint');
    }
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
        print('Token exchange failed: ${tokenResponse.body}');
      }
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

    // Clean up
    html.window.sessionStorage.remove('dex_verifier');

    if (kDebugMode) {
      print('✅ OAuth login successful (redirect flow)');
    }
    return true;
  }
}
