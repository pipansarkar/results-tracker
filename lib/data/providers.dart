import 'dart:convert';

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

final ordersProvider = FutureProvider<List<OrderWin>>(
  (ref) => ref.watch(repositoryProvider).orders(),
);

final iposProvider = FutureProvider<IpoBoard>(
  (ref) => ref.watch(repositoryProvider).ipos(),
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

/// Several named watchlists, saved on the device. Push alerts follow the
/// union of all lists (FCM topic per stock).
class WatchlistsNotifier extends Notifier<Map<String, List<String>>> {
  static const _key = 'watchlists';
  static const _legacyKey = 'watchlist';
  static const defaultName = 'My watchlist';

  @override
  Map<String, List<String>> build() {
    final prefs = ref.read(prefsProvider);
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        return {
          for (final e in m.entries) e.key: List<String>.from(e.value as List),
        };
      } catch (_) {}
    }
    // Migrate the old single watchlist.
    return {defaultName: prefs.getStringList(_legacyKey) ?? const []};
  }

  Set<String> get _all => {for (final l in state.values) ...l};

  Future<void> _save(Map<String, List<String>> next) async {
    final before = _all;
    state = next;
    await ref.read(prefsProvider).setString(_key, jsonEncode(next));
    if (!ref.read(firebaseEnabledProvider)) return;
    final after = _all;
    for (final s in after.difference(before)) {
      await _syncTopic(s, true);
    }
    for (final s in before.difference(after)) {
      await _syncTopic(s, false);
    }
  }

  List<String> listsWith(String symbol) => [
    for (final e in state.entries)
      if (e.value.contains(symbol)) e.key,
  ];

  Future<void> toggle(String symbol, {String? list}) async {
    final name = list ?? state.keys.first;
    final cur = state[name] ?? const [];
    final next = {...state};
    next[name] = cur.contains(symbol)
        ? cur.where((s) => s != symbol).toList()
        : [...cur, symbol];
    await _save(next);
  }

  /// Toggle in every list at once (used when there is only one list).
  Future<void> removeEverywhere(String symbol) async => _save({
    for (final e in state.entries)
      e.key: e.value.where((s) => s != symbol).toList(),
  });

  Future<bool> create(String name) async {
    name = name.trim();
    if (name.isEmpty || state.containsKey(name)) return false;
    await _save({...state, name: const []});
    return true;
  }

  Future<bool> rename(String from, String to) async {
    to = to.trim();
    if (to.isEmpty || state.containsKey(to) || !state.containsKey(from))
      return false;
    await _save({
      for (final e in state.entries) (e.key == from ? to : e.key): e.value,
    });
    return true;
  }

  Future<void> delete(String name) async {
    final next = {...state}..remove(name);
    await _save(next.isEmpty ? {defaultName: const []} : next);
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

final watchlistsProvider =
    NotifierProvider<WatchlistsNotifier, Map<String, List<String>>>(
      WatchlistsNotifier.new,
    );

/// Every stock in any watchlist (for "Watchlist only" filters).
final watchlistProvider = Provider<List<String>>(
  (ref) =>
      {for (final l in ref.watch(watchlistsProvider).values) ...l}.toList(),
);

// ------------------------------------------------------------ saved screens

class SavedScreen {
  final String id, name;
  final Map<String, List<double?>> filters;
  final String? sector;
  final bool n500;
  final List<String> caps;
  const SavedScreen(
    this.id,
    this.name,
    this.filters, {
    this.sector,
    this.n500 = false,
    this.caps = const [],
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'filters': filters,
    'sector': sector,
    'n500': n500,
    'caps': caps,
  };

  factory SavedScreen.fromJson(Map<String, dynamic> m) => SavedScreen(
    m['id'] as String,
    m['name'] as String,
    {
      for (final e in (m['filters'] as Map).entries)
        e.key as String: [
          for (final v in e.value as List) (v as num?)?.toDouble(),
        ],
    },
    sector: m['sector'] as String?,
    n500: m['n500'] as bool? ?? false,
    caps: List<String>.from(m['caps'] as List? ?? const []),
  );
}

/// Screens saved on this device; each is also registered with the pipeline
/// (screens/{id}) and subscribed to the FCM topic screen_{id} for alerts.
class SavedScreensNotifier extends Notifier<List<SavedScreen>> {
  static const _key = 'savedScreens';

  @override
  List<SavedScreen> build() {
    final raw = ref.read(prefsProvider).getString(_key);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          SavedScreen.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persist() => ref
      .read(prefsProvider)
      .setString(_key, jsonEncode([for (final s in state) s.toJson()]));

  Future<void> save(
    String name,
    Map<String, List<double?>> filters, {
    String? sector,
    bool n500 = false,
    List<String> caps = const [],
  }) async {
    String id = 'local-${DateTime.now().millisecondsSinceEpoch}';
    try {
      id =
          await ref
              .read(repositoryProvider)
              .saveScreen(
                name,
                filters,
                sector: sector,
                n500: n500,
                caps: caps,
              ) ??
          id;
      if (ref.read(firebaseEnabledProvider)) {
        await FirebaseMessaging.instance.requestPermission();
        await FirebaseMessaging.instance.subscribeToTopic('screen_$id');
      }
    } catch (e) {
      debugPrint('save screen failed: $e');
    }
    state = [
      ...state,
      SavedScreen(id, name, filters, sector: sector, n500: n500, caps: caps),
    ];
    await _persist();
  }

  Future<void> delete(String id) async {
    state = state.where((s) => s.id != id).toList();
    await _persist();
    if (ref.read(firebaseEnabledProvider)) {
      try {
        await FirebaseMessaging.instance.unsubscribeFromTopic('screen_$id');
      } catch (_) {}
    }
  }
}

final savedScreensProvider =
    NotifierProvider<SavedScreensNotifier, List<SavedScreen>>(
      SavedScreensNotifier.new,
    );
