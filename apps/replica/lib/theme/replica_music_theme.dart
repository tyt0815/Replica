import 'package:flutter/material.dart';

const Color replicaAccentColor = Color(0xFFFF0035);
const Color replicaLightNavBarColor = Color(0xFFF1F1F1);

final _replicaPageTransitions = PageTransitionsTheme(
  builders: {
    for (final platform in TargetPlatform.values)
      platform: const _ReplicaPageTransition(),
  },
);

class _ReplicaPageTransition extends PageTransitionsBuilder {
  const _ReplicaPageTransition();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 280);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 240);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => SlideTransition(
    position: animation.drive(
      Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
    ),
    child: child,
  );
}

ThemeData buildReplicaLightTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: replicaAccentColor,
    onPrimary: Colors.white,
    secondary: Color(0xFF18181B),
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFF4F4F5),
    onSecondaryContainer: Color(0xFF18181B),
    error: Color(0xFFDC2626),
    onError: Colors.white,
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF09090B),
    onSurfaceVariant: Color(0xFF71717A),
    outline: Color(0xFFE4E4E7),
    outlineVariant: Color(0xFFD4D4D8),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFFAFAFA),
    surfaceContainer: Color(0xFFF4F4F5),
    surfaceContainerHigh: Color(0xFFF1F1F1),
    surfaceContainerHighest: Color(0xFFE4E4E7),
  );
  return ThemeData(
    useMaterial3: true,
    pageTransitionsTheme: _replicaPageTransitions,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFFFFFFF),
    dividerColor: const Color(0xFFE4E4E7),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFFFFFFF),
      foregroundColor: Color(0xFF09090B),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFFFFFFFF),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE4E4E7)),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFFFFFFFF),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF18181B),
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF09090B),
        side: const BorderSide(color: Color(0xFFE4E4E7)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFF52525B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      ),
    ),
  );
}

ThemeData buildReplicaDarkTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: replicaAccentColor,
    onPrimary: Colors.white,
    secondary: Color(0xFFFAFAFA),
    onSecondary: Color(0xFF09090B),
    secondaryContainer: Color(0xFF1F1F23),
    onSecondaryContainer: Color(0xFFFAFAFA),
    error: Color(0xFFEF4444),
    onError: Color(0xFF09090B),
    surface: Color(0xFF09090B),
    onSurface: Color(0xFFFAFAFA),
    onSurfaceVariant: Color(0xFFA1A1AA),
    outline: Color(0xFF27272A),
    outlineVariant: Color(0xFF3F3F46),
    surfaceContainerLowest: Color(0xFF09090B),
    surfaceContainerLow: Color(0xFF0F0F12),
    surfaceContainer: Color(0xFF141418),
    surfaceContainerHigh: Color(0xFF1C1C21),
    surfaceContainerHighest: Color(0xFF27272A),
  );
  return ThemeData(
    useMaterial3: true,
    pageTransitionsTheme: _replicaPageTransitions,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF09090B),
    dividerColor: const Color(0xFF27272A),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF09090B),
      foregroundColor: Color(0xFFFAFAFA),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF121215),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFF27272A)),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF121215),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFFAFAFA),
        foregroundColor: const Color(0xFF09090B),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFFAFAFA),
        side: const BorderSide(color: Color(0xFF27272A)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFFA1A1AA),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      ),
    ),
  );
}
