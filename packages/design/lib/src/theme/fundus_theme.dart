import 'package:flutter/material.dart';

import '../tokens/fundus_metrics.dart';
import '../tokens/fundus_typography.dart';
import 'fundus_tokens.dart';

/// Builds the Material theme from the Nocturne tokens.
///
/// Material 3 is the base, but the app must not read as stock Android: filled
/// primaries become accent outlines, the focus ring is the accent's own, and
/// every surface comes from the ramps rather than from a seed colour.
abstract final class FundusTheme {
  /// [accent] recolours the interface without redesigning it: the ramp keeps
  /// its lightness curve and moves to the chosen hue, so contrast survives
  /// whatever somebody picks.
  static ThemeData dark({
    FundusDensity density = FundusDensity.comfortable,
    Color? accent,
  }) => _build(
    FundusTokens.dark(density: density, accent: accent),
    Brightness.dark,
  );

  static ThemeData light({
    FundusDensity density = FundusDensity.comfortable,
    Color? accent,
  }) => _build(
    FundusTokens.light(density: density, accent: accent),
    Brightness.light,
  );

  static ThemeData of(
    Brightness brightness,
    FundusDensity density, {
    Color? accent,
  }) => brightness == Brightness.dark
      ? dark(density: density, accent: accent)
      : light(density: density, accent: accent);

  static ThemeData _build(FundusTokens tokens, Brightness brightness) {
    final textTheme = FundusType.textTheme(
      text: tokens.text,
      muted: tokens.textMuted,
    );
    final scheme = ColorScheme(
      brightness: brightness,
      primary: tokens.accent,
      onPrimary: brightness == Brightness.dark
          ? tokens.accentRamp.s900
          : tokens.accentRamp.s100,
      secondary: tokens.accentSecondaryRamp.s500,
      onSecondary: tokens.text,
      error: tokens.danger,
      onError: tokens.dangerGround,
      surface: tokens.surface,
      onSurface: tokens.text,
      surfaceContainerLowest: tokens.background,
      surfaceContainer: tokens.surface,
      surfaceContainerHigh: tokens.surfaceRaised,
      outline: tokens.divider,
      outlineVariant: tokens.neutral.s800,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: tokens.background,
      canvasColor: tokens.background,
      dividerColor: tokens.divider,
      textTheme: textTheme,
      fontFamily: FundusType.fontFamily,
      fontFamilyFallback: FundusType.fallback,
      extensions: [tokens],
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        color: tokens.divider,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: tokens.textMuted, size: 18),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: FundusRadius.smAll,
          border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: tokens.text),
        waitDuration: const Duration(milliseconds: 500),
      ),
      // The primary action is an accent outline on transparent, never a fill.
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? tokens.accentTint(0.22)
                : states.contains(WidgetState.hovered)
                ? tokens.accentTint(0.12)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.all(tokens.accent),
          side: WidgetStateProperty.all(BorderSide(color: tokens.accent)),
          shape: WidgetStateProperty.all(
            const RoundedRectangleBorder(borderRadius: FundusRadius.mdAll),
          ),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(
              horizontal: FundusSpace.x6,
              vertical: FundusSpace.x3,
            ),
          ),
          textStyle: WidgetStateProperty.all(textTheme.labelLarge),
          elevation: WidgetStateProperty.all(0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(tokens.text),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered)
                ? tokens.hover
                : Colors.transparent,
          ),
          side: WidgetStateProperty.all(BorderSide(color: tokens.divider)),
          shape: WidgetStateProperty.all(
            const RoundedRectangleBorder(borderRadius: FundusRadius.mdAll),
          ),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(
              horizontal: FundusSpace.x4,
              vertical: FundusSpace.x3,
            ),
          ),
          textStyle: WidgetStateProperty.all(textTheme.bodyMedium),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(tokens.textMuted),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered)
                ? tokens.hover
                : Colors.transparent,
          ),
          shape: WidgetStateProperty.all(
            const RoundedRectangleBorder(borderRadius: FundusRadius.mdAll),
          ),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(
              horizontal: FundusSpace.x4,
              vertical: FundusSpace.x2,
            ),
          ),
          textStyle: WidgetStateProperty.all(textTheme.bodyMedium),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(tokens.textMuted),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered)
                ? tokens.hover
                : Colors.transparent,
          ),
          shape: WidgetStateProperty.all(
            const RoundedRectangleBorder(borderRadius: FundusRadius.mdAll),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: FundusSpace.x4,
          vertical: FundusSpace.x3,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: tokens.textFaint),
        border: OutlineInputBorder(
          borderRadius: FundusRadius.mdAll,
          borderSide: BorderSide(color: tokens.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: FundusRadius.mdAll,
          borderSide: BorderSide(color: tokens.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: FundusRadius.mdAll,
          borderSide: BorderSide(color: tokens.accent, width: 1.4),
        ),
      ),
      cardTheme: CardThemeData(
        color: tokens.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: FundusRadius.lgAll,
          side: BorderSide(color: tokens.divider),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: FundusRadius.lgAll,
          side: BorderSide(color: tokens.divider),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: tokens.surface,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: FundusRadius.lg),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: tokens.surfaceRaised,
        contentTextStyle: textTheme.bodyMedium,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: FundusRadius.mdAll),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: tokens.accent,
        linearTrackColor: tokens.divider,
        linearMinHeight: 4,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: FundusRadius.md,
        thumbColor: WidgetStatePropertyAll(tokens.neutral.s800),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: tokens.textMuted,
        textColor: tokens.text,
        shape: const RoundedRectangleBorder(borderRadius: FundusRadius.mdAll),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? tokens.accentRamp.s200
              : tokens.neutral.s500,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? tokens.accent
              : tokens.neutral.s800,
        ),
        trackOutlineColor: WidgetStatePropertyAll(tokens.divider),
      ),
    );
  }
}
