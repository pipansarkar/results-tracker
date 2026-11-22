import 'i18n_strings.dart';

/// Current UI language: en | bn | hi. Set by the app root from the
/// language setting; the whole app rebuilds when it changes.
String appLang = 'en';

/// Translates an English UI string. Falls back to English when a
/// translation is missing, so untranslated text never breaks the UI.
String tr(String en) {
  if (appLang == 'en') return en;
  return (appLang == 'bn' ? bnStrings : hiStrings)[en] ?? en;
}
