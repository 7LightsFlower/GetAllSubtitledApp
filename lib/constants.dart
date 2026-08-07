// constants.dart

// ─── App title ──────────────────────────────────────────────────
const String appTitle = 'Subtitles in many languages';

// ─── Server addresses ──────────────────────────────────────────
/// Public URL where the web app is hosted (frontend) 
const String publicServerUrl = 'https://GetAllSubtitled.dataforlearningmachines.com';
// const String publicServerUrl = 'http://localhost:5000';

/// Internal backend server (all API calls except registration)
const String internalServerUrl = 'https://lt2srv-sscherrer.isl.iar.kit.edu';

// ─── Environment mode (for local testing) ─────────────────────
const bool isDevelopment = true;   // set false for production

// ─── API endpoints ─────────────────────────────────────────────
/// Authentication (login, register, forgot password)
const String authBaseUrl = isDevelopment
    ? 'http://localhost:5000'   // or internalServerUrl
    : publicServerUrl;

const String videoApiBaseUrl = internalServerUrl;   // video processing

// ─── Internal server credentials (for auto‑login) ─────────────
/// Replace these with your actual internal server credentials.
const String internalEmail = 'admin@example.com';    // <-- replace with your real internal credentials
const String internalPassword = 'YourActualPassword123';         // <-- replace

// ─── Dummy credentials for testing (not auto‑filled) ─────────
const String dummyEmail = 'testuser@example.com';
const String dummyPassword = 'YourSecurePassword123';

// ─── Dex OAuth 2.0 Configuration ──────────────────────────────
const String dexClientId = 'traefik-forward-auth';
const String dexClientSecret = 'XXXXXXXXX';   // <-- replace with your actual client secret from 
/// docker ps | grep dex
/// docker inspect <docker_id> | grep -i secret
/// const String dexRedirectUri = 'http://localhost:5000/oauth_callback.html';
const String dexRedirectUri = 'https://lt2srv-sscherrer.isl.iar.kit.edu/_oauth';
const String dexIssuer = 'https://lt2srv-sscherrer.isl.iar.kit.edu/dex';
const List<String> dexScopes = ['openid', 'profile', 'email'];
