// flutter_bootstrap.js — custom start script (Flutter fills in the two
// placeholder lines below at build time).
//
// Cache busting: every build loads its assets (icon font, images,
// AssetManifest, FontManifest …) from its own address
//     /v/<build id>/assets/…
// The Dockerfile replaces __BUILD_ID__ with the build time; nginx maps
// /v/<anything>/… back to the real files. A new build = new addresses,
// so no browser can keep using files of an older build.
// This script itself is served with "no-cache", so it is always current.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    assetBase: "/v/__BUILD_ID__/",
  },
});
