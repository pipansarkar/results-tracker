import 'package:flutter/material.dart';

const _seed = Color(0xFF1F5EFF);
const gainColor = Color(0xFF16A34A);
const lossColor = Color(0xFFDC2626);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    appBarTheme: const AppBarTheme(centerTitle: false),
  );
}
