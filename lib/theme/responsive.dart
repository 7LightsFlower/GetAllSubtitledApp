// lib/theme/responsive.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Coarse class of the current viewport. Used when a widget only needs
/// "is this a phone, a tablet, or a wide screen?" and doesn't care
/// about exact pixel counts.
enum ScreenClass { compact, medium, expanded, large }

/// Central, screen-aware sizing for the whole app.
///
/// Usage inside a widget:
///   final r = Responsive.of(context);
///   Container(height: r.videoHeight)
///   Text('hi', style: TextStyle(fontSize: r.fontBody))
///
/// The object is cheap to construct (a few float multiplies) and is
/// safe to call once per build method. Do not cache it across frames;
/// a window resize should re-create it.
class Responsive {
  /// The full logical size of the viewport.
  final Size size;

  /// Short side in logical pixels (min of width and height).
  final double shortSide;

  /// Long side in logical pixels (max of width and height).
  final double longSide;

  /// The class of the current viewport. Uses Material 3's
  /// window-size-class boundaries adapted for the web:
  ///
  ///   compact   < 600 px short side   (phone)
  ///   medium    < 840 px short side   (small tablet / narrow window)
  ///   expanded  < 1200 px long side   (tablet / laptop)
  ///   large     >= 1200 px long side  (desktop monitor)
  final ScreenClass screenClass;

  /// Portrait when height > width.
  final bool isPortrait;

  const Responsive._({
    required this.size,
    required this.shortSide,
    required this.longSide,
    required this.screenClass,
    required this.isPortrait,
  });

  factory Responsive.of(BuildContext context) {
    final media = MediaQuery.of(context);
    final s = media.size;
    final short = math.min(s.width, s.height);
    final long = math.max(s.width, s.height);

    // Note the asymmetry: short side gates phone/tablet, long side
    // gates laptop/desktop. A 1920×600 browser window is wide but
    // short; classifying it by short side alone would call it a
    // phone. Classifying by long side gets it right.
    final ScreenClass cls;
    if (short < 600) {
      cls = ScreenClass.compact;
    } else if (short < 840) {
      cls = ScreenClass.medium;
    } else if (long < 1200) {
      cls = ScreenClass.expanded;
    } else {
      cls = ScreenClass.large;
    }

    return Responsive._(
      size: s,
      shortSide: short,
      longSide: long,
      screenClass: cls,
      isPortrait: s.height > s.width,
    );
  }

  // ─── Convenience flags ──────────────────────────────────────────
  bool get isCompact => screenClass == ScreenClass.compact;
  bool get isMedium => screenClass == ScreenClass.medium;
  bool get isExpanded => screenClass == ScreenClass.expanded;
  bool get isLarge => screenClass == ScreenClass.large;

  /// True for anything wider than a phone in landscape.
  bool get isWideLayout => screenClass != ScreenClass.compact;

  // ─── Dimensions ─────────────────────────────────────────────────
  double get width => size.width;
  double get height => size.height;

  // ─── Scaling helpers ────────────────────────────────────────────
  //
  // Every base number below is expressed in "reference pixels" that
  // represent a 1440 × 900 logical desktop window. `_scale` maps those
  // to actual pixels using the viewport's short side, clamped so the
  // text stays legible on tiny phones and doesn't become silly on 4K.
  //
  // The class multiplier on top adds a small nudge so a 1200-wide
  // "expanded" screen reads slightly denser than a 599-wide compact
  // even when both have the same short side (rare, but possible).

  /// Short side we treat as 1.0 in the scaling formula.
  static const double _referenceSide = 900.0;

  /// Bounds on the raw ratio. Prevents a 320-px phone from producing
  /// microscopic fonts and a 4K monitor from producing paragraph-sized
  /// ones.
  static const double _minRatio = 0.75;
  static const double _maxRatio = 1.35;

  double get _ratio =>
      (shortSide / _referenceSide).clamp(_minRatio, _maxRatio);

  double _fontScale(double base) {
    final classNudge = switch (screenClass) {
      ScreenClass.compact => 0.95,
      ScreenClass.medium => 1.0,
      ScreenClass.expanded => 1.02,
      ScreenClass.large => 1.05,
    };
    return base * _ratio * classNudge;
  }

  double _spaceScale(double base) {
    final classNudge = switch (screenClass) {
      ScreenClass.compact => 0.9,
      ScreenClass.medium => 1.0,
      ScreenClass.expanded => 1.05,
      ScreenClass.large => 1.1,
    };
    return base * _ratio * classNudge;
  }

  // ─── Video pane ─────────────────────────────────────────────────
  /// Height of the video area. Sized as a fraction of the viewport
  /// height, but bounded so the video is never less than ~180 px and
  /// never eats more than ~45 % of the screen.
  double get videoHeight {
    final raw = switch (screenClass) {
      ScreenClass.compact => height * 0.30,
      ScreenClass.medium => height * 0.28,
      ScreenClass.expanded => height * 0.24,
      ScreenClass.large => height * 0.22,
    };
    return raw.clamp(180.0, math.min(height * 0.45, 420.0));
  }

  /// Max width of the video pane inside the black letterbox.
  /// On tall/narrow layouts we allow almost the whole width; on wide
  /// layouts we cap so the video doesn't become a thin strip.
  double get videoMaxWidth {
    if (isPortrait) return width * 0.95;
    return width * 0.85;
  }

  /// Height of the chapter strip below the video. Matches the visual
  /// weight of a video-player scrubber.
  double get chapterBarHeight => _spaceScale(6).clamp(4.0, 10.0);

  // ─── Subtitle overlay ───────────────────────────────────────────
  double get subtitleOverlayFont => _fontScale(12).clamp(10.0, 18.0);
  double get subtitleOverlayBottom =>
      (videoHeight * 0.26).clamp(40.0, 90.0);
  double get subtitleOverlayHorizontal =>
      _spaceScale(10).clamp(6.0, 18.0);
  double get subtitleOverlayVertical =>
      _spaceScale(4).clamp(2.0, 10.0);

  // ─── Font sizes ─────────────────────────────────────────────────
  double get fontCaption => _fontScale(10).clamp(9.0, 13.0);
  double get fontSmall => _fontScale(11).clamp(10.0, 14.0);
  double get fontBodySmall => _fontScale(12).clamp(11.0, 15.0);
  double get fontBody => _fontScale(13).clamp(12.0, 16.0);
  double get fontBodyLarge => _fontScale(14).clamp(13.0, 17.0);
  double get fontSubtitle => _fontScale(16).clamp(14.0, 20.0);
  double get fontTitle => _fontScale(20).clamp(18.0, 26.0);
  double get fontTitleLarge => _fontScale(22).clamp(20.0, 30.0);

  // ─── Named, screen-specific fonts ──────────────────────────────
  double get fileListTitleFont => _fontScale(12).clamp(11.0, 15.0);
  double get fileListMetaFont => _fontScale(10).clamp(9.0, 13.0);
  double get editingHeaderFont => _fontScale(13).clamp(12.0, 16.0);
  double get segmentTimestampFont => _fontScale(10).clamp(9.0, 13.0);
  double get segmentTimestampSmFont => _fontScale(9).clamp(8.0, 12.0);
  double get segmentTextFont => _fontScale(12).clamp(11.0, 15.0);
  double get markupChipFont => _fontScale(9).clamp(8.0, 12.0);

  // ─── Spacing ────────────────────────────────────────────────────
  double get spaceXS => _spaceScale(4).clamp(2.0, 8.0);
  double get spaceS => _spaceScale(8).clamp(4.0, 14.0);
  double get spaceM => _spaceScale(12).clamp(8.0, 20.0);
  double get spaceL => _spaceScale(16).clamp(12.0, 26.0);
  double get spaceXL => _spaceScale(24).clamp(18.0, 40.0);

  // ─── Icons ──────────────────────────────────────────────────────
  double get iconSmall => _fontScale(16).clamp(14.0, 20.0);
  double get iconMedium => _fontScale(20).clamp(18.0, 26.0);
  double get iconLarge => _fontScale(24).clamp(20.0, 32.0);
  double get iconExtraLarge => _fontScale(64).clamp(48.0, 96.0);

  // ─── Grid helpers (used by working_screen and friends) ─────────
  /// How many columns a project grid should use at this viewport.
  ///
  /// Chosen so cards stay close to 260–320 px wide on any display:
  ///   phone portrait   → 2
  ///   phone landscape  → 3
  ///   tablet / laptop  → 4
  ///   desktop          → 5
  ///   4K desktop       → 6
  ///
  /// `minCardWidth` is the smallest acceptable card width in logical
  /// pixels. Callers can override it if their card is unusually wide
  /// or narrow.
  int gridColumns({
    double minCardWidth = 240,
    int maxColumns = 6,
    double horizontalPadding = 32,
  }) {
    final usableWidth = width - horizontalPadding;
    if (usableWidth <= 0) return 1;
    final fit = (usableWidth / minCardWidth).floor();
    return fit.clamp(1, maxColumns);
  }

  /// Suggested card aspect ratio for the project grid. Tightens as
  /// the card gets narrower so the metadata block stays readable.
  double gridCardAspectRatio({double? columnWidth}) {
    final cw = columnWidth ?? (width / gridColumns());
    if (cw < 220) return 0.70;
    if (cw < 300) return 0.75;
    if (cw < 380) return 0.82;
    return 0.90;
  }

  /// True when the viewport is tall enough that we can show a side
  /// panel next to the video without squeezing either.
  bool get canShowSidePanel =>
      screenClass == ScreenClass.large && isPortrait == false;
}