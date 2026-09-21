// lib/theme/responsive.dart
import 'package:flutter/material.dart';

/// Breakpoints: shortest side of the screen.
enum ScreenClass { mobile, tablet, desktop }

/// Central, screen-aware sizing for the whole app.
///
/// Usage inside a widget:
///   final r = Responsive.of(context);
///   Container(height: r.videoHeight, ...)
///   Text('hi', style: TextStyle(fontSize: r.fontBody))
class Responsive {
  final Size size;
  final ScreenClass screenClass;
  final double width;
  final double height;

  const Responsive._({
    required this.size,
    required this.screenClass,
    required this.width,
    required this.height,
  });

  factory Responsive.of(BuildContext context) {
    final media = MediaQuery.of(context);
    final shortest = media.size.shortestSide;
    final cls = shortest < 600
        ? ScreenClass.mobile
        : (shortest < 1024 ? ScreenClass.tablet : ScreenClass.desktop);
    return Responsive._(
      size: media.size,
      screenClass: cls,
      width: media.size.width,
      height: media.size.height,
    );
  }

  bool get isMobile  => screenClass == ScreenClass.mobile;
  bool get isTablet  => screenClass == ScreenClass.tablet;
  bool get isDesktop => screenClass == ScreenClass.desktop;

  // ─── Scaling helpers ─────────────────────────────────────────────
  double _fontScale(double base) {
    switch (screenClass) {
      case ScreenClass.mobile:  return base * 0.9;
      case ScreenClass.tablet:  return base;
      case ScreenClass.desktop: return base * 1.05;
    }
  }

  double _spaceScale(double base) {
    switch (screenClass) {
      case ScreenClass.mobile:  return base * 0.85;
      case ScreenClass.tablet:  return base;
      case ScreenClass.desktop: return base * 1.1;
    }
  }

  // ─── Video window ────────────────────────────────────────────────
  /// Height of the video pane. Roomier than before so the player's
  /// own controls have space and the video itself feels bigger.
  double get videoHeight {
    switch (screenClass) {
      case ScreenClass.mobile:  return (height * 0.30).clamp(150.0, 240.0);
      case ScreenClass.tablet:  return (height * 0.25).clamp(180.0, 280.0);
      case ScreenClass.desktop: return (height * 0.22).clamp(200.0, 340.0);
    }
  }

  // ─── Chapter bar ────────────────────────────────────────────────
  /// Thickness of the chapter strip below the video. Matches the
  /// visual weight of a video-player scrubber.
  double get chapterBarHeight => _spaceScale(6);

  double get videoMaxWidth => width * 0.9;

  // ─── Font sizes ──────────────────────────────────────────────────
  // Generic
  double get fontCaption     => _fontScale(10);
  double get fontSmall       => _fontScale(11);
  double get fontBodySmall   => _fontScale(12);
  double get fontBody        => _fontScale(13);
  double get fontBodyLarge   => _fontScale(14);
  double get fontSubtitle    => _fontScale(16);
  double get fontTitle       => _fontScale(20);
  double get fontTitleLarge  => _fontScale(22);

  // Named, screen-specific
  
  // ─── Subtitle overlay placement ─────────────────────────────────
  /// Small caption text, clear of the player's own control bar.
  double get subtitleOverlayFont     => _fontScale(12);

  double get fileListTitleFont       => _fontScale(12);
  double get fileListMetaFont        => _fontScale(10);
  double get editingHeaderFont       => _fontScale(13);
  double get segmentTimestampFont    => _fontScale(10);
  double get segmentTimestampSmFont  => _fontScale(9);
  double get segmentTextFont         => _fontScale(12);
  double get markupChipFont          => _fontScale(9);

  // ─── Spacing ────────────────────────────────────────────────────
  double get spaceXS => _spaceScale(4);
  double get spaceS  => _spaceScale(8);
  double get spaceM  => _spaceScale(12);
  double get spaceL  => _spaceScale(16);
  double get spaceXL => _spaceScale(24);

  // ─── Icons ──────────────────────────────────────────────────────
  double get iconSmall      => _fontScale(16);
  double get iconMedium     => _fontScale(20);
  double get iconLarge      => _fontScale(24);
  double get iconExtraLarge => _fontScale(64);

  /// Bottom offset of the subtitle pill, from the bottom of the
  /// video pane. Scales with the pane so it always clears the
  /// player's timeline / play button.
  double get subtitleOverlayBottom   => (videoHeight * 0.26).clamp(40.0, 80.0);

  double get subtitleOverlayHorizontal => _spaceScale(10);
  double get subtitleOverlayVertical   => _spaceScale(4);

  }