import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/firestore_repository.dart';
import 'firebase_options.dart';
import 'data/providers.dart';
import 'data/repository.dart';
import 'data/seed_repository.dart';

/// Run with `--dart-define=SAMPLE=true` to force offline sample data.
const _forceSample = bool.fromEnvironment('SAMPLE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  // Firebase config lives in lib/firebase_options.dart (flutterfire configure).
  // If Firebase can't start, the app falls back to sample data.
  var firebaseOk = false;
  if (!_forceSample) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      firebaseOk = true;
    } catch (e) {
      debugPrint('Firebase unavailable, using sample data: $e');
    }
  }

  final Repository repo = firebaseOk ? FirestoreRepository() : SeedRepository();

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        repositoryProvider.overrideWithValue(repo),
        firebaseEnabledProvider.overrideWithValue(firebaseOk),
      ],
      child: const ResultsTrackerApp(),
    ),
  );
}
