import 'package:flutter/material.dart';

import '../tokens/fundus_metrics.dart';
import '../tokens/fundus_palette.dart';

/// Every Nocturne value the interface needs, carried on the theme.
///
/// Read it with `context.fundus`. Nothing outside `fundus_design` spells a
/// colour or a raw pixel number — that rule is what keeps dark and light
/// equally maintained instead of one of them rotting.
@immutable
final class FundusTokens extends ThemeExtension<FundusTokens> {
  const FundusTokens({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.divider,
    required this.neutral,
    required this.accentRamp,
    required this.accentSecondaryRamp,
    required this.success,
    required this.successGround,
    required this.warning,
    required this.warningGround,
    required this.danger,
    required this.dangerGround,
    required this.density,
  });

  factory FundusTokens.dark({
    FundusDensity density = FundusDensity.comfortable,
  }) {
    const neutral = FundusPalette.neutral;
    return FundusTokens(
      background: FundusPalette.darkBackground,
      surface: FundusPalette.darkSurface,
      surfaceRaised: const Color(0xff20243a),
      text: FundusPalette.darkText,
      textMuted: neutral.s500,
      textFaint: neutral.s600,
      accent: FundusPalette.darkAccent,
      divider: FundusPalette.darkText.withValues(alpha: 0.16),
      neutral: neutral,
      accentRamp: FundusPalette.accent,
      accentSecondaryRamp: FundusPalette.accentSecondary,
      success: FundusPalette.darkSuccess,
      successGround: FundusPalette.darkSuccessGround,
      warning: FundusPalette.darkWarning,
      warningGround: FundusPalette.darkWarningGround,
      danger: FundusPalette.darkDanger,
      dangerGround: FundusPalette.darkDangerGround,
      density: density,
    );
  }

  factory FundusTokens.light({
    FundusDensity density = FundusDensity.comfortable,
  }) {
    final neutral = FundusPalette.neutral.reversed;
    return FundusTokens(
      background: FundusPalette.lightBackground,
      surface: FundusPalette.lightSurface,
      surfaceRaised: const Color(0xffeceafa),
      text: FundusPalette.lightText,
      textMuted: neutral.s500,
      textFaint: neutral.s400,
      accent: FundusPalette.lightAccent,
      divider: FundusPalette.lightText.withValues(alpha: 0.14),
      neutral: neutral,
      accentRamp: FundusPalette.accent.reversed,
      accentSecondaryRamp: FundusPalette.accentSecondary.reversed,
      success: FundusPalette.lightSuccess,
      successGround: FundusPalette.lightSuccessGround,
      warning: FundusPalette.lightWarning,
      warningGround: FundusPalette.lightWarningGround,
      danger: FundusPalette.lightDanger,
      dangerGround: FundusPalette.lightDangerGround,
      density: density,
    );
  }

  final Color background;
  final Color surface;

  /// The step above [surface] — selected rows, the active navigation entry.
  final Color surfaceRaised;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color accent;
  final Color divider;

  final FundusRamp neutral;
  final FundusRamp accentRamp;
  final FundusRamp accentSecondaryRamp;

  final Color success;
  final Color successGround;
  final Color warning;
  final Color warningGround;
  final Color danger;
  final Color dangerGround;

  final FundusDensity density;

  bool get isDark => background.computeLuminance() < 0.5;

  /// A quiet tint of the accent for hovers and outlined fills.
  Color accentTint(double amount) => accent.withValues(alpha: amount);

  /// The hover ground used throughout the shell: a tint of the text colour,
  /// so it works on both themes without a second token.
  Color get hover => text.withValues(alpha: 0.06);

  /// The pressed step is one past the base, taken from the ramp rather than
  /// mixed ad hoc.
  Color get accentPressed => isDark ? accentRamp.s400 : accentRamp.s600;

  /// Elevation. On a dark ground elevation is a hairline edge plus ambient
  /// darkness — never a stack of heavy shadows.
  List<BoxShadow> get shadowSm => [
    BoxShadow(color: neutral.s800, spreadRadius: 1, blurRadius: 0),
  ];

  List<BoxShadow> get shadowMd => [
    BoxShadow(color: neutral.s700, spreadRadius: 1, blurRadius: 0),
    BoxShadow(
      color: const Color(0xff000000).withValues(alpha: isDark ? 0.55 : 0.12),
      blurRadius: 18,
      offset: const Offset(0, 6),
    ),
  ];

  List<BoxShadow> get shadowLg => [
    BoxShadow(color: neutral.s500, spreadRadius: 1, blurRadius: 0),
    BoxShadow(
      color: const Color(0xff000000).withValues(alpha: isDark ? 0.65 : 0.16),
      blurRadius: 40,
      offset: const Offset(0, 16),
    ),
  ];

  @override
  FundusTokens copyWith({FundusDensity? density}) => FundusTokens(
    background: background,
    surface: surface,
    surfaceRaised: surfaceRaised,
    text: text,
    textMuted: textMuted,
    textFaint: textFaint,
    accent: accent,
    divider: divider,
    neutral: neutral,
    accentRamp: accentRamp,
    accentSecondaryRamp: accentSecondaryRamp,
    success: success,
    successGround: successGround,
    warning: warning,
    warningGround: warningGround,
    danger: danger,
    dangerGround: dangerGround,
    density: density ?? this.density,
  );

  @override
  FundusTokens lerp(ThemeExtension<FundusTokens>? other, double t) {
    if (other is! FundusTokens) return this;
    return FundusTokens(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      neutral: FundusRamp.lerp(neutral, other.neutral, t),
      accentRamp: FundusRamp.lerp(accentRamp, other.accentRamp, t),
      accentSecondaryRamp: FundusRamp.lerp(
        accentSecondaryRamp,
        other.accentSecondaryRamp,
        t,
      ),
      success: Color.lerp(success, other.success, t)!,
      successGround: Color.lerp(successGround, other.successGround, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningGround: Color.lerp(warningGround, other.warningGround, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerGround: Color.lerp(dangerGround, other.dangerGround, t)!,
      density: t < 0.5 ? density : other.density,
    );
  }
}

extension FundusTokensAccess on BuildContext {
  /// The Nocturne tokens for the current theme.
  FundusTokens get fundus => Theme.of(this).extension<FundusTokens>()!;
}
