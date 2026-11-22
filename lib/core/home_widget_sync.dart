import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';

/// Writes today's results and the watchlist's next events to the Android
/// home-screen widget. Safe to call often; does nothing off Android.
Future<void> syncHomeWidget({
  required List<FeedItem> today,
  required List<CalendarDay> calendar,
  required List<String> watchlist,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final mine = today.where((f) => watchlist.contains(f.symbol)).toList();
    final todayLine = today.isEmpty
        ? 'No results announced yet today'
        : '${today.length} results today'
              '${mine.isEmpty ? '' : ' · ${mine.length} from your watchlists'}';
    final fmt = DateFormat('d MMM');
    final upcoming = <String>[];
    for (final d in calendar.where((d) => !d.date.isBefore(start))) {
      for (final e in d.events.where(
        (e) => watchlist.isEmpty || watchlist.contains(e.symbol),
      )) {
        final what = switch (e.type) {
          EventType.results => 'Results',
          EventType.concall => 'Concall',
          EventType.investorMeet => 'Investor meet',
          EventType.corpAction => e.note ?? 'Corporate action',
        };
        upcoming.add(
          '${fmt.format(d.date)} · ${e.name} · $what${e.time != null ? ' ${e.time}' : ''}',
        );
        if (upcoming.length >= 4) break;
      }
      if (upcoming.length >= 4) break;
    }
    await HomeWidget.saveWidgetData<String>(
      'title',
      watchlist.isEmpty ? 'Results Tracker' : 'My watchlists',
    );
    await HomeWidget.saveWidgetData<String>('today', todayLine);
    await HomeWidget.saveWidgetData<String>(
      'events',
      upcoming.isEmpty
          ? 'No upcoming results or concalls for your watchlists'
          : upcoming.join('\n'),
    );
    await HomeWidget.saveWidgetData<String>(
      'updated',
      'Updated ${DateFormat('d MMM, h:mm a').format(now)}',
    );
    await HomeWidget.updateWidget(
      qualifiedAndroidName:
          'com.example.results_tracker.WatchlistWidgetProvider',
    );
  } catch (e) {
    debugPrint('home widget sync skipped: $e');
  }
}
