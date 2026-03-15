import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum YappaAccentPreset {
  crimson,
  violet,
  ocean,
  emerald,
  amber,
  custom,
}

enum YappaFontPreset {
  system,
  serif,
  monospace,
}

class NewChatColors {
  static Color background = const Color(0xFF0B0D11);
  static Color panel = const Color(0xFF11141A);
  static Color panelAlt = const Color(0xFF171B22);
  static Color surface = const Color(0xFF1C212A);
  static Color surfaceSoft = const Color(0xFF252B36);
  static Color outline = const Color(0xFF313947);
  static Color textMuted = const Color(0xFF97A0B2);

  static Color accent = const Color(0xFF7B1424);
  static Color accentSoft = const Color(0xFFB02D41);
  static Color accentGlow = const Color(0xFFDA5368);

  static Color success = const Color(0xFF43C083);
  static Color warning = const Color(0xFFD0A146);
  static Color info = const Color(0xFF58A6FF);
}

class YappaAppearance {
  static const _accentKey = 'yappa_accent_preset';
  static const _fontKey = 'yappa_font_preset';
  static const _customAccentKey = 'yappa_custom_accent_hex';

  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  static YappaAccentPreset accentPreset = YappaAccentPreset.crimson;
  static YappaFontPreset fontPreset = YappaFontPreset.system;
  static Color customAccentGlow = const Color(0xFFDA5368);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final savedAccent = prefs.getString(_accentKey);
    final savedFont = prefs.getString(_fontKey);
    final savedCustomAccent = prefs.getString(_customAccentKey);

    accentPreset = YappaAccentPreset.values.firstWhere(
      (value) => value.name == savedAccent,
      orElse: () => YappaAccentPreset.crimson,
    );

    fontPreset = YappaFontPreset.values.firstWhere(
      (value) => value.name == savedFont,
      orElse: () => YappaFontPreset.system,
    );

    customAccentGlow = _colorFromHex(savedCustomAccent) ?? const Color(0xFFDA5368);

    _applyAccentPreset(accentPreset);
  }

  static Future<void> setAccentPreset(YappaAccentPreset preset) async {
    accentPreset = preset;
    _applyAccentPreset(preset);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentKey, preset.name);

    notifier.value = notifier.value + 1;
  }

  static Future<void> setCustomAccentColor(Color color) async {
    customAccentGlow = color;
    accentPreset = YappaAccentPreset.custom;
    _applyCustomAccentColor(color);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentKey, YappaAccentPreset.custom.name);
    await prefs.setString(_customAccentKey, _colorToHex(color));

    notifier.value = notifier.value + 1;
  }

  static Future<void> setFontPreset(YappaFontPreset preset) async {
    fontPreset = preset;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontKey, preset.name);

    notifier.value = notifier.value + 1;
  }

  static String? get currentFontFamily {
    switch (fontPreset) {
      case YappaFontPreset.system:
        return null;
      case YappaFontPreset.serif:
        return 'serif';
      case YappaFontPreset.monospace:
        return 'monospace';
    }
  }

  static void _applyAccentPreset(YappaAccentPreset preset) {
    switch (preset) {
      case YappaAccentPreset.crimson:
        NewChatColors.accent = const Color(0xFF7B1424);
        NewChatColors.accentSoft = const Color(0xFFB02D41);
        NewChatColors.accentGlow = const Color(0xFFDA5368);
        break;
      case YappaAccentPreset.violet:
        NewChatColors.accent = const Color(0xFF5B2A86);
        NewChatColors.accentSoft = const Color(0xFF7D4CB0);
        NewChatColors.accentGlow = const Color(0xFFB07DFF);
        break;
      case YappaAccentPreset.ocean:
        NewChatColors.accent = const Color(0xFF0E5A73);
        NewChatColors.accentSoft = const Color(0xFF1684A6);
        NewChatColors.accentGlow = const Color(0xFF54C7EC);
        break;
      case YappaAccentPreset.emerald:
        NewChatColors.accent = const Color(0xFF14663E);
        NewChatColors.accentSoft = const Color(0xFF1F935A);
        NewChatColors.accentGlow = const Color(0xFF55D28E);
        break;
      case YappaAccentPreset.amber:
        NewChatColors.accent = const Color(0xFF8A4E08);
        NewChatColors.accentSoft = const Color(0xFFB56A11);
        NewChatColors.accentGlow = const Color(0xFFFFB347);
        break;
      case YappaAccentPreset.custom:
        _applyCustomAccentColor(customAccentGlow);
        break;
    }
  }

  static void _applyCustomAccentColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    final accent = hsl
        .withSaturation((hsl.saturation * 0.88).clamp(0.35, 1.0))
        .withLightness((hsl.lightness * 0.46).clamp(0.16, 0.34))
        .toColor();
    final accentSoft = hsl
        .withSaturation((hsl.saturation * 0.94).clamp(0.40, 1.0))
        .withLightness((hsl.lightness * 0.72).clamp(0.26, 0.52))
        .toColor();
    final accentGlow = hsl
        .withSaturation(hsl.saturation.clamp(0.45, 1.0))
        .withLightness(hsl.lightness.clamp(0.42, 0.72))
        .toColor();

    NewChatColors.accent = accent;
    NewChatColors.accentSoft = accentSoft;
    NewChatColors.accentGlow = accentGlow;
  }

  static String _colorToHex(Color color) {
    final value = color.toARGB32();
    return value.toRadixString(16).padLeft(8, '0').toUpperCase();
  }

  static Color? _colorFromHex(String? hex) {
    if (hex == null || hex.trim().isEmpty) return null;
    final normalized = hex.replaceAll('#', '').trim();
    if (normalized.length != 8) return null;
    final value = int.tryParse(normalized, radix: 16);
    if (value == null) return null;
    return Color(value);
  }
}

ThemeData buildYappaTheme() {
  final colorScheme = ColorScheme.dark(
    primary: NewChatColors.accentGlow,
    secondary: NewChatColors.warning,
    surface: NewChatColors.surface,
    error: const Color(0xFFF17878),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: NewChatColors.background,
    fontFamily: YappaAppearance.currentFontFamily,
    cardTheme: CardThemeData(
      color: NewChatColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: NewChatColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.zero,
          topRight: Radius.circular(24),
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
      ),
      titleLarge: TextStyle(
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
      titleMedium: TextStyle(fontWeight: FontWeight.w700),
      bodyLarge: TextStyle(height: 1.45),
      bodyMedium: TextStyle(height: 1.45),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NewChatColors.surface,
      labelStyle: TextStyle(color: NewChatColors.textMuted),
      hintStyle: TextStyle(color: NewChatColors.textMuted),
      prefixIconColor: NewChatColors.textMuted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: NewChatColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: NewChatColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: NewChatColors.accentGlow, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NewChatColors.accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: NewChatColors.outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      selectedIconTheme: IconThemeData(color: NewChatColors.accentGlow),
      selectedLabelTextStyle: TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
      ),
      unselectedIconTheme: IconThemeData(color: NewChatColors.textMuted),
      unselectedLabelTextStyle: TextStyle(
        color: NewChatColors.textMuted,
      ),
      backgroundColor: Colors.transparent,
      indicatorColor: NewChatColors.warning,
    ),
    dividerColor: NewChatColors.outline,
  );
}