// constants.dart

// ─── App title ──────────────────────────────────────────────────
const String appTitle = 'Subtitles in many languages';

// ─── Server addresses ──────────────────────────────────────────
/// Public URL where the web app is hosted (frontend) 
const String publicServerUrl = 'https://GetAllSubtitled.dataforlearningmachines.com';
// const String publicServerUrl = 'http://localhost:5000';

/// Internal backend server (all API calls except registration)
const String internalServerUrl = 'https://lt2srv-sscherrer.isl.iar.kit.edu';

/// Your merged Flask server - MUST BE LOCALHOST FOR DEVELOPMENT
/// This is where the Flutter app sends the video for processing
const String flaskServerUrl = 'http://localhost:5000';

// ─── Environment mode (for local testing) ─────────────────────
const bool isDevelopment = true;   // set false for production

// ─── API endpoints ─────────────────────────────────────────────
/// Authentication (login, register, forgot password)
const String authBaseUrl = isDevelopment
    ? 'http://localhost:5000'   // Use local server in development
    : publicServerUrl;

const String videoApiBaseUrl = internalServerUrl;   // video processing

// ─── Internal server credentials (for auto‑login) ─────────────
const String internalEmail = 'admin@example.com';
const String internalPassword = 'YourActualPassword123';

// ─── Dummy credentials for testing ────────────────────────────
const String dummyEmail = 'testuser@example.com';
const String dummyPassword = 'YourSecurePassword123';

// ─── Dex OAuth 2.0 Configuration ──────────────────────────────
const String dexClientId = 'traefik-forward-auth';
const String dexClientSecret = 'bar';
const String dexRedirectUri = 'http://localhost:8080/';
const String dexIssuer = 'https://lt2srv-sscherrer.isl.iar.kit.edu/dex';
const List<String> dexScopes = ['openid', 'profile', 'email'];
