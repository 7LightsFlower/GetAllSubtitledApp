// internal_auth_service.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asr_live_translator/constants.dart';

class InternalAuthService {
  static const String _accessTokenKey = 'internal_access_token';
  static const String _refreshTokenKey = 'internal_refresh_token';
  static const String _idTokenKey = 'internal_id_token';
  static const String _expiryKey = 'internal_token_expiry';

  static const FlutterAppAuth _appAuth = FlutterAppAuth();

  // ─── OAuth2 login via Dex ──────────────────────────────────────────
  static Future<bool> loginWithOAuth() async {
    try {
      final authorizationResponse = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          dexClientId,
          dexRedirectUri,
          issuer: dexIssuer,
          scopes: dexScopes,
          // usePKCE is true by default, so we can omit it
        ),
      );

      if (authorizationResponse.accessToken != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_accessTokenKey, authorizationResponse.accessToken!);
        if (authorizationResponse.refreshToken != null) {
          await prefs.setString(_refreshTokenKey, authorizationResponse.refreshToken!);
        }
        if (authorizationResponse.idToken != null) {
          await prefs.setString(_idTokenKey, authorizationResponse.idToken!);
        }
        // Store expiry
        if (authorizationResponse.accessTokenExpirationDateTime != null) {
          final expiry = authorizationResponse.accessTokenExpirationDateTime!
              .toUtc()
              .toIso8601String();
          await prefs.setString(_expiryKey, expiry);
        } else {
          // fallback: assume 1 hour
          final expiry = DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String();
          await prefs.setString(_expiryKey, expiry);
        }
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) print('OAuth login error: $e');
      return false;
    }
  }

  // ─── Get a valid access token (refresh if needed) ────────────────
  static Future<String?> getValidAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString(_accessTokenKey);
    final refreshToken = prefs.getString(_refreshTokenKey);
    final expiryStr = prefs.getString(_expiryKey);

    if (accessToken == null) return null;

    // Check if token is expired
    if (expiryStr != null) {
      final expiry = DateTime.parse(expiryStr);
      if (DateTime.now().toUtc().isBefore(expiry)) {
        return accessToken;
      }
    }

    // Try to refresh
    if (refreshToken != null) {
      try {
        final tokenResponse = await _appAuth.token(
          TokenRequest(
            dexClientId,
            dexRedirectUri,
            issuer: dexIssuer,
            refreshToken: refreshToken,
            scopes: dexScopes,
          ),
        );
        if (tokenResponse.accessToken != null) {
          await prefs.setString(_accessTokenKey, tokenResponse.accessToken!);
          if (tokenResponse.refreshToken != null) {
            await prefs.setString(_refreshTokenKey, tokenResponse.refreshToken!);
          }
          if (tokenResponse.idToken != null) {
            await prefs.setString(_idTokenKey, tokenResponse.idToken!);
          }
          if (tokenResponse.accessTokenExpirationDateTime != null) {
            final expiry = tokenResponse.accessTokenExpirationDateTime!
                .toUtc()
                .toIso8601String();
            await prefs.setString(_expiryKey, expiry);
          }
          return tokenResponse.accessToken;
        }
      } catch (e) {
        if (kDebugMode) print('Token refresh failed: $e');
      }
    }

    // If we get here, refresh failed or no refresh token – clear and return null
    await clearTokens();
    return null;
  }

  // ─── Clear all tokens ──────────────────────────────────────────────
  static Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_idTokenKey);
    await prefs.remove(_expiryKey);
  }

  // ─── Legacy compatibility methods (if needed) ─────────────────────
  static Future<String?> getToken() async => getValidAccessToken();
  static Future<void> clearToken() async => clearTokens();
}
