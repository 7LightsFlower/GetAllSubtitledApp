// constants.dart

// ─── App title ──────────────────────────────────────────────────
const String appTitle = 'Subtitles in many languages';

// ─── Environment mode ─────────────────────────────────────────
// true  → local `flutter run -d chrome`
// false → production (Docker / Nginx)
const bool isDevelopment = false;

// ─── Server addresses ─────────────────────────────────────────
/// Public URL where the web app is hosted (frontend, i.e. the browser origin).
/// Used only for display / OAuth redirects, NOT as an API base.
const String publicServerUrl = 'https://getallsubtitledapp.isl.iar.kit.edu';

/// Internal backend server (video processing + Dex OAuth; separate service).
/// No trailing slash.
const String internalServerUrl = 'https://lt2srv-sscherrer.isl.iar.kit.edu';

/// Base for all same-server API calls (login, /videos, /upload, ...).
///
/// `String.fromEnvironment` is evaluated at build time:
///   - when `--dart-define=API_BASE_URL=...` is given → that value wins
///   - when it is not given → `defaultValue` is used
///
/// The Dockerfile passes `API_BASE_URL=''` for production, so all API
/// calls become relative URLs resolved against the page's origin
/// (works behind Nginx or any reverse proxy).
const String flaskServerUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: isDevelopment ? 'http://localhost:5000' : '',
);

/// Same value as [flaskServerUrl]; kept as a separate name for clarity
/// at call sites that deal with auth.
const String authBaseUrl = flaskServerUrl;

/// Video processing endpoint (the external/internal service).
const String videoApiBaseUrl = internalServerUrl;

// ─── Internal server credentials (for auto-login) ─────────────
const String internalEmail = 'admin@example.com';
const String internalPassword = 'YourActualPassword123';

// ─── Dummy credentials for testing ────────────────────────────
const String dummyEmail = 'testuser@example.com';
const String dummyPassword = 'YourSecurePassword123';

// ─── Dex OAuth 2.0 Configuration ──────────────────────────────
const String dexClientId = 'traefik-forward-auth';
const String dexClientSecret = 'YourSecretKeyHere'; // Must match the Dex client secret in the Dex config.
const List<String> dexScopes = ['openid', 'profile', 'email'];

/// Dex is mounted on the internal server host.
const String dexIssuer = '$internalServerUrl/dex';

/// Must match the redirect URI registered with the Dex client:
/// localhost during development, the public origin in production.
const String dexRedirectUri = isDevelopment
    ? 'http://localhost:8080/'
    : '$publicServerUrl/';
