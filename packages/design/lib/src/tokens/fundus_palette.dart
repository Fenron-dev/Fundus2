import 'package:flutter/painting.dart';

/// A 100–900 tonal ramp generated in OKLCH on one shared lightness scale, so
/// the same step of any role carries the same visual weight.
///
/// On the dark ground the low steps (100–300) are the light ones and are used
/// for text on tinted fills; the high steps (700–900) are the dark ones and
/// carry fills, hovers and subtle borders. The light theme reuses the very
/// same values with the roles swapped, which is why both themes share one
/// class instead of two hand-tuned palettes.
final class FundusRamp {
  const FundusRamp({
    required this.s100,
    required this.s200,
    required this.s300,
    required this.s400,
    required this.s500,
    required this.s600,
    required this.s700,
    required this.s800,
    required this.s900,
  });

  final Color s100;
  final Color s200;
  final Color s300;
  final Color s400;
  final Color s500;
  final Color s600;
  final Color s700;
  final Color s800;
  final Color s900;

  /// The same ramp in another hue.
  ///
  /// A ramp is not nine arbitrary colours: it is one hue at nine carefully
  /// chosen lightnesses, and that curve is what makes text on it readable in
  /// both themes. Recolouring therefore keeps the curve and moves the hue —
  /// the saturation is nudged towards the chosen colour so a grey choice
  /// really goes grey, but never so far that a step loses its contrast.
  FundusRamp shiftedTo(Color seed) {
    final target = HSLColor.fromColor(seed);
    Color recolour(Color step) {
      final hsl = HSLColor.fromColor(step);
      final saturation = target.saturation < 0.08
          ? target.saturation
          : (hsl.saturation * 0.65 + target.saturation * 0.35).clamp(0.0, 1.0);
      return hsl
          .withHue(target.hue)
          .withSaturation(saturation.toDouble())
          .toColor();
    }

    return FundusRamp(
      s100: recolour(s100),
      s200: recolour(s200),
      s300: recolour(s300),
      s400: recolour(s400),
      s500: recolour(s500),
      s600: recolour(s600),
      s700: recolour(s700),
      s800: recolour(s800),
      s900: recolour(s900),
    );
  }

  /// The ramp read from the other end — the light theme's assignment.
  FundusRamp get reversed => FundusRamp(
    s100: s900,
    s200: s800,
    s300: s700,
    s400: s600,
    s500: s500,
    s600: s400,
    s700: s300,
    s800: s200,
    s900: s100,
  );

  Color step(int value) => switch (value) {
    100 => s100,
    200 => s200,
    300 => s300,
    400 => s400,
    500 => s500,
    600 => s600,
    700 => s700,
    800 => s800,
    900 => s900,
    _ => throw ArgumentError.value(value, 'value', 'no such ramp step'),
  };

  static FundusRamp lerp(FundusRamp a, FundusRamp b, double t) => FundusRamp(
    s100: Color.lerp(a.s100, b.s100, t)!,
    s200: Color.lerp(a.s200, b.s200, t)!,
    s300: Color.lerp(a.s300, b.s300, t)!,
    s400: Color.lerp(a.s400, b.s400, t)!,
    s500: Color.lerp(a.s500, b.s500, t)!,
    s600: Color.lerp(a.s600, b.s600, t)!,
    s700: Color.lerp(a.s700, b.s700, t)!,
    s800: Color.lerp(a.s800, b.s800, t)!,
    s900: Color.lerp(a.s900, b.s900, t)!,
  );
}

/// The raw Nocturne values. Nothing outside this file spells a colour out.
abstract final class FundusPalette {
  // Grounds.
  static const darkBackground = Color(0xff161826);
  static const darkSurface = Color(0xff232532);
  static const darkText = Color(0xffe9e9ed);
  static const darkAccent = Color(0xff9184d9);

  static const lightBackground = Color(0xfff1f0f8);
  static const lightSurface = Color(0xfffbfaff);
  static const lightText = Color(0xff1a1826);
  static const lightAccent = Color(0xff6e62b0);

  /// Ramps as written in `styles.css`, i.e. in the dark theme's assignment.
  static const neutral = FundusRamp(
    s100: Color(0xfff3f5fe),
    s200: Color(0xffe4e7f5),
    s300: Color(0xffcfd3e5),
    s400: Color(0xffb2b6ca),
    s500: Color(0xff9397ab),
    s600: Color(0xff75798c),
    s700: Color(0xff595d6c),
    s800: Color(0xff3f424d),
    s900: Color(0xff292b31),
  );

  static const accent = FundusRamp(
    s100: Color(0xfff5f4ff),
    s200: Color(0xffe7e5fe),
    s300: Color(0xffd2cefd),
    s400: Color(0xffb5abfc),
    s500: Color(0xff968ae0),
    s600: Color(0xff796cbf),
    s700: Color(0xff5d5294),
    s800: Color(0xff423a6a),
    s900: Color(0xff2b2741),
  );

  /// The second accent is a machine-derived stand-in in the same hue; the
  /// system treats it as one role with [accent] and it is kept only so both
  /// sets resolve.
  static const accentSecondary = FundusRamp(
    s100: Color(0xfff5f4ff),
    s200: Color(0xffe7e5fe),
    s300: Color(0xffd2cefd),
    s400: Color(0xffb5afe8),
    s500: Color(0xff9690c9),
    s600: Color(0xff7972a9),
    s700: Color(0xff5c5783),
    s800: Color(0xff423e5d),
    s900: Color(0xff2b293a),
  );

  // State colours. The marketing tokens did not need these; the app does.
  static const darkSuccess = Color(0xff8fcf95);
  static const darkSuccessGround = Color(0xff213626);
  static const darkWarning = Color(0xffe0b273);
  static const darkWarningGround = Color(0xff3a2c18);
  static const darkDanger = Color(0xffe28e8e);
  static const darkDangerGround = Color(0xff3a2020);

  static const lightSuccess = Color(0xff3f7a46);
  static const lightSuccessGround = Color(0xffe3f1e4);
  static const lightWarning = Color(0xff8a6323);
  static const lightWarningGround = Color(0xfff5ead4);
  static const lightDanger = Color(0xffa13f3f);
  static const lightDangerGround = Color(0xfff6dede);

  /// Origin marks. These five never change colour and never move — the whole
  /// point is that they are recognised without reading.
  static const originLocal = Color(0xff7fb08a);
  static const originStream = Color(0xffa7a1db);
  static const originOffline = Color(0xff9184d9);
  static const originUnreachable = Color(0xffb4707a);
  static const originArchive = Color(0xffc9a15e);
}
