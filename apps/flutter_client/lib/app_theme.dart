import 'package:flutter/material.dart';
import 'app_motion.dart';

class AppTheme {
  static const accent = Color(0xFF3478F6);
  static const background = Color(0xFFF5F7FB);
  static const line = Color(0xFFE5EAF2);
  static const text = Color(0xFF232936);
  static const muted = Color(0xFF667085);
  static const subtle = Color(0xFF98A2B3);
  static const success = Color(0xFF21A67A);
  static const danger = Color(0xFFE45C64);
  static const surfaceSoft = Color(0xFFF7F9FC);
  static const cardRadius = 16.0;

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(seedColor: accent).copyWith(
      primary: accent,
      error: danger,
      surface: Colors.white,
      onSurface: const Color(0xFF232936),
      onSurfaceVariant: const Color(0xFF667085),
      outlineVariant: line,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cardRadius),
      side: const BorderSide(color: line),
    );
    return ThemeData(
      useMaterial3: true,
      pageTransitionsTheme: AppMotion.pageTransitions,
      colorScheme: scheme,
      textTheme: const TextTheme(
        titleMedium:
            TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.4),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5),
        bodySmall: TextStyle(fontSize: 12, height: 1.5),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: Color(0xFF667085),
        titleTextStyle: TextStyle(
            color: Color(0xFF232936),
            fontSize: 14,
            fontWeight: FontWeight.w600),
        subtitleTextStyle:
            TextStyle(color: Color(0xFF667085), fontSize: 12, height: 1.5),
      ),
      dialogTheme: DialogThemeData(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      ),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(foregroundColor: muted)),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFF232936),
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceSoft,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        animationDuration: AppMotion.feedback,
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        animationDuration: AppMotion.feedback,
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      )),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFFECF3FF),
        height: 68,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: 23,
              color: states.contains(WidgetState.selected)
                  ? accent
                  : scheme.onSurfaceVariant,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: states.contains(WidgetState.selected)
                  ? accent
                  : scheme.onSurfaceVariant,
            )),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: Color(0xFFECF3FF),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
