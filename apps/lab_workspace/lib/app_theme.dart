import 'package:flutter/material.dart';

const _canvas = Color(0xFFF4F7F6);
const _surface = Color(0xFFFFFFFF);
const _ink = Color(0xFF203331);
const _mutedInk = Color(0xFF63736F);
const _accent = Color(0xFF14776F);
const _outline = Color(0xFFDCE6E3);

ThemeData buildLabWorkspaceTheme() {
  final base = ThemeData(
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: _accent,
          brightness: Brightness.light,
        ).copyWith(
          primary: _accent,
          onPrimary: Colors.white,
          secondary: const Color(0xFF557F88),
          surface: _surface,
          onSurface: _ink,
          outline: _outline,
          error: const Color(0xFFB54748),
          onError: Colors.white,
        ),
    scaffoldBackgroundColor: _canvas,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
  );

  final text = base.textTheme.apply(bodyColor: _ink, displayColor: _ink);

  return base.copyWith(
    textTheme: text.copyWith(
      headlineLarge: text.headlineLarge?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        height: 1.12,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.55,
        height: 1.16,
      ),
      headlineSmall: text.headlineSmall?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.35,
        height: 1.2,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      bodyMedium: text.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.5,
        color: _mutedInk,
      ),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 12,
        height: 1.45,
        color: _mutedInk,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: _canvas,
      foregroundColor: _ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 24,
      toolbarHeight: 68,
      titleTextStyle: TextStyle(
        color: _ink,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
    ),
    cardTheme: CardThemeData(
      color: _surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _outline, width: 0.8),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF8FAF9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      labelStyle: const TextStyle(color: _mutedInk),
      hintStyle: const TextStyle(color: Color(0xFF8A9894)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFB54748)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: _ink,
        side: const BorderSide(color: _outline),
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        textStyle: const TextStyle(fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: _accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: const Color(0xFFEAF3F1),
      side: const BorderSide(color: Color(0xFFD8E8E4)),
      labelStyle: const TextStyle(
        color: Color(0xFF315C56),
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      iconColor: const Color(0xFF53706A),
      titleTextStyle: const TextStyle(
        color: _ink,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: const TextStyle(
        color: _mutedInk,
        fontSize: 12,
        height: 1.45,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: _outline,
      thickness: 0.8,
      space: 1,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: _surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: const TextStyle(
        color: _ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: const TextStyle(color: _mutedInk, height: 1.5),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: _canvas,
      indicatorColor: const Color(0xFFDDEEEA),
      selectedIconTheme: const IconThemeData(color: _accent, size: 22),
      unselectedIconTheme: const IconThemeData(
        color: Color(0xFF63736F),
        size: 21,
      ),
      selectedLabelTextStyle: const TextStyle(
        color: _accent,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: const TextStyle(
        color: _mutedInk,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      minWidth: 68,
      minExtendedWidth: 236,
      groupAlignment: -0.9,
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: _surface,
      indicatorColor: const Color(0xFFDDEEEA),
      tileHeight: 52,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      backgroundColor: const Color(0xFF263B38),
      contentTextStyle: const TextStyle(color: Colors.white),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: _accent,
      linearTrackColor: Color(0xFFDCE9E5),
    ),
  );
}
