import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

enum _Filter { all, results, concalls, meets }

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  _Filter _filter = _Filter.all;
  bool _watchlistOnly = false;

  bool _keep(CalendarEvent e, List<String> watchlist) {
    if (_watchlistOnly && !watchlist.contains(e.symbol)) return false;
    return switch (_filter) {
      _Filter.all => true,
      _Filter.results => e.type == EventType.results,
      _Filter.concalls => e.type == EventType.concall,
      _Filter.meets => e.type == EventType.investorMeet,
    };
  }

  List<CalendarDay> _filtered(List<CalendarDay> days, List<String> watchlist) =>
      [
        for (final d in days)
          if (d.events.where((e) => _keep(e, watchlist)).toList() case final ev
              when ev.isNotEmpty)
            CalendarDay(d.date, ev),
      ];

  @override
  Widget build(BuildContext context) {
    final calendar = ref.watch(calendarProvider);
    final watchlist = ref.watch(watchlistProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Results Calendar'),
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => context.push('/search'),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Upcoming'),
              Tab(text: 'Past'),
            ],
          ),
        ),
        body: Column(
          children: [
            const SampleDataBanner(),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  for (final f in _Filter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(switch (f) {
                          _Filter.all => 'All',
                          _Filter.results => 'Results',
                          _Filter.concalls => 'Concalls',
                          _Filter.meets => 'Investor meets',
                        }),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                    ),
                  FilterChip(
                    label: const Text('Watchlist'),
                    selected: _watchlistOnly,
                    onSelected: (v) => setState(() => _watchlistOnly = v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: calendar.when(
                loading: () => loading,
                error: asyncError,
                data: (days) {
                  final all = _filtered(days, watchlist);
                  final upcoming = all
                      .where((d) => !d.date.isBefore(today))
                      .toList();
                  final past = all.where((d) => d.date.isBefore(today)).toList()
                    ..sort((a, b) => b.date.compareTo(a.date));
                  return TabBarView(
                    children: [
                      _DayList(
                        upcoming,
                        empty: 'Nothing scheduled in the next 45 days.',
                      ),
                      _DayList(past, empty: 'No events in the last 60 days.'),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayList extends ConsumerWidget {
  const _DayList(this.days, {required this.empty});
  final List<CalendarDay> days;
  final String empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (days.isEmpty) {
      return EmptyState(icon: Icons.event_busy, message: empty);
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(calendarProvider),
      child: ListView(
        children: [
          for (final d in days) ...[
            SectionHeader(
              d.date == today
                  ? 'Today · ${dayFormat.format(d.date)}'
                  : dayFormat.format(d.date),
              trailing: Text(
                '${d.events.length} event${d.events.length == 1 ? '' : 's'}',
              ),
            ),
            for (final e in d.events) _EventTile(e),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile(this.e);
  final CalendarEvent e;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, bg, fg, label) = switch (e.type) {
      EventType.results => (
        Icons.bar_chart,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        'Results',
      ),
      EventType.concall => (
        Icons.call,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        'Concall',
      ),
      EventType.investorMeet => (
        Icons.groups,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        'Investor meet',
      ),
    };
    final sym = Uri.encodeComponent(e.symbol);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: bg,
        child: Icon(icon, color: fg),
      ),
      title: Text(e.name),
      subtitle: Text(
        '${e.symbol} · $label${e.note == null ? '' : ' · ${e.note}'}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.hasSummary)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.summarize_outlined, size: 18),
            ),
          if (e.time != null) Text(e.time!),
          WatchButton(e.symbol),
        ],
      ),
      onTap: () => context.push(
        e.hasSummary && e.period != null
            ? '/company/$sym/concall/${e.period}'
            : '/company/$sym',
      ),
    );
  }
}
