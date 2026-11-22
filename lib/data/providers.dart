import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'media_news.dart';
import 'repository.dart';

/// Overridden in main() with Firestore or Seed implementation.
final repositoryProvider = Provider<Repository>(
  (ref) => throw UnimplementedError(),
);

/// Overridden in main().
final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(),
);

/// True when Firebase initialised (push notifications available).
final firebaseEnabledProvider = Provider<bool>((ref) => false);

final companiesProvider = FutureProvider<List<CompanyLite>>(
  (ref) => ref.watch(repositoryProvider).allCompanies(),
);

final todayFeedProvider = StreamProvider<List<FeedItem>>(
  (ref) => ref.watch(repositoryProvider).todayFeed(),
);

/// Past 60 days and next 45 days.
final calendarProvider = FutureProvider<List<CalendarDay>>((ref) {
  final now = DateTime.now();
  return ref
      .watch(repositoryProvider)
      .calendar(
        now.subtract(const Duration(days: 60)),
        now.add(const Duration(days: 45)),
      );
});

final companyProvider = StreamProvider.family<Company?, String>(
  (ref, symbol) => ref.watch(repositoryProvider).company(symbol),
);

final concallsProvider = FutureProvider.family<List<Concall>, String>(
  (ref, symbol) => ref.watch(repositoryProvider).concalls(symbol),
);

final guidanceProvider = FutureProvider.family<List<GuidanceItem>, String>(
  (ref, symbol) => ref.watch(repositoryProvider).guidance(symbol),
);

final screenerProvider = FutureProvider<List<StockMetrics>>(
  (ref) => ref.watch(repositoryProvider).screener(),
);

/// Ratios for one stock (from the shared screener data).
final metricsProvider = Provider.family<StockMetrics?, String>(
  (ref, symbol) => ref
      .watch(screenerProvider)
      .value
      ?.where((m) => m.symbol == symbol)
      .firstOrNull,
);

final activityProvider = FutureProvider.family<List<ActivityItem>, String>(
  (ref, symbol) => ref.watch(repositoryProvider).activity(symbol),
);

final marketDealsProvider = FutureProvider<List<MarketDeal>>(
  (ref) => ref.watch(repositoryProvider).marketDeals(),
);

final seasonProvider = FutureProvider<Season?>(
  (ref) => ref.watch(repositoryProvider).season(),
);

final filingsProvider = FutureProvider.family<List<NewsItem>, String>(
  (ref, symbol) => ref.watch(repositoryProvider).filings(symbol),
);

final mediaNewsServiceProvider = Provider<MediaNews>((ref) => MediaNews());

/// Media headlines for (symbol, company name).
final mediaNewsProvider =
    FutureProvider.family<List<NewsItem>, (String, String)>(
      (ref, key) =>
          ref.watch(mediaNewsServiceProvider).forCompany(key.$2, key.$1),
    );

// ---------------------------------------------------------------- watchlist

class WatchlistNotifier extends Notifier<List<String>> {
  static const _key = 'watchlist';

  @override
  List<String> build() =>
      ref.read(prefsProvider).getStringList(_key) ?? const [];

  bool contains(String symbol) => state.contains(symbol);

  Future<void> toggle(String symbol) async {
    final adding = !state.contains(symbol);
    state = adding
        ? [...state, symbol]
        : state.where((s) => s != symbol).toList();
    await ref.read(prefsProvider).setStringList(_key, state);
    if (ref.read(firebaseEnabledProvider)) {
      await _syncTopic(symbol, adding);
    }
  }

  Future<void> _syncTopic(String symbol, bool subscribe) async {
    try {
      final fm = FirebaseMessaging.instance;
      if (subscribe) {
        await fm.requestPermission();
        await fm.subscribeToTopic(topicForSymbol(symbol));
      } else {
        await fm.unsubscribeFromTopic(topicForSymbol(symbol));
      }
    } catch (e) {
      debugPrint('FCM topic sync failed: $e');
    }
  }
}

final watchlistProvider = NotifierProvider<WatchlistNotifier, List<String>>(
  WatchlistNotifier.new,
);

// ---------------------------------------------------------------- language

/// Summary language: en | bn | hi
class LanguageNotifier extends Notifier<String> {
  static const _key = 'lang';

  @override
  String build() => ref.read(prefsProvider).getString(_key) ?? 'en';

  Future<void> set(String lang) async {
    state = lang;
    await ref.read(prefsProvider).setString(_key, lang);
  }
}

final languageProvider = NotifierProvider<LanguageNotifier, String>(
  LanguageNotifier.new,
);

const languageNames = {'en': 'English', 'bn': 'বাংলা', 'hi': 'हिंदी'};
