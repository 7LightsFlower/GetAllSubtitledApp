// ui_mode.dart
//
// App-wide Simple / Expert switch.
//
//   Simple  — only what is needed to get a result: languages, start,
//             progress, results. Default for new users.
//   Expert  — every setting, server picker, job history, technical
//             details (codecs, segments, sources, raw responses, …).
//
// The choice is stored in SharedPreferences (browser local storage on
// the web), so it survives reloads. Screens listen to [UiMode.expert]
// and rebuild when it flips; [UiModeToggle] is the button that goes
// into every AppBar's `actions`.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UiMode {
  UiMode._();

  static const String _prefsKey = 'ui_expert_mode';

  /// true = Expert, false = Simple.
  static final ValueNotifier<bool> expert = ValueNotifier<bool>(false);

  static bool get isExpert => expert.value;
  static bool get isSimple => !expert.value;

  /// Call once at startup (before runApp) so the first frame already
  /// shows the remembered mode.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      expert.value = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      // Storage blocked (private window etc.) — stay in Simple.
    }
  }

  static Future<void> set(bool value) async {
    expert.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, value);
    } catch (_) {}
  }

  static Future<void> toggle() => set(!expert.value);
}

/// Mixin for State classes: rebuilds the screen when the mode flips.
mixin UiModeListener<T extends StatefulWidget> on State<T> {
  void _onUiModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    UiMode.expert.addListener(_onUiModeChanged);
  }

  @override
  void dispose() {
    UiMode.expert.removeListener(_onUiModeChanged);
    super.dispose();
  }
}

/// Simple ◯━ Expert switch for an AppBar: both labels are always
/// visible, the active one is bold, the thumb sits on the active side.
/// Tapping either label or the switch flips the mode.
class UiModeToggle extends StatelessWidget {
  const UiModeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: UiMode.expert,
      builder: (context, expert, _) {
        final narrow = MediaQuery.sizeOf(context).width < 600;
        // Inside an AppBar, IconTheme carries the bar's foreground colour
        // (each screen sets its own), so the switch matches the icons.
        final fg = IconTheme.of(context).color ??
            DefaultTextStyle.of(context).style.color ??
            Colors.white;

        Widget label(String text, bool active, bool targetExpert) {
          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => UiMode.set(targetExpert),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),
                style: TextStyle(
                  color: active ? fg : fg.withValues(alpha: 0.55),
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  fontSize: narrow ? 12 : 13,
                ),
                child: Text(text),
              ),
            ),
          );
        }

        return Tooltip(
          message: expert
              ? 'Expert mode: all settings and details'
              : 'Simple mode: only the main options',
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: narrow ? 2 : 8),
            child: Semantics(
              label: 'Expert mode',
              toggled: expert,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  label('Simple', !expert, false),
                  Transform.scale(
                    scale: narrow ? 0.75 : 0.85,
                    child: Switch(
                      value: expert,
                      onChanged: UiMode.set,
                      // Neutral track both ways: neither mode is "off".
                      activeThumbColor: fg,
                      activeTrackColor: fg.withValues(alpha: 0.35),
                      inactiveThumbColor: fg,
                      inactiveTrackColor: fg.withValues(alpha: 0.35),
                      trackOutlineColor:
                          WidgetStatePropertyAll(fg.withValues(alpha: 0.6)),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  label('Expert', expert, true),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
