import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  bool _watchlistOnly = false;

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(todayFeedProvider);
    final calendar = ref.watch(calendarProvider);
    final watchlist = ref.watch(watchlistProvider);
    final todayId = dateId(DateTime.now());

    bool keep(String s) => !_watchlistOnly || watchlist.contains(s);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Today's Results"),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: Column(
        children: [
          const SampleDataBanner(),
          const StockSearchBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(todayFeedProvider);
                ref.invalidate(calendarProvider);
              },
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            dayFormat.format(DateTime.now()),
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                        FilterChip(
                          label: const Text('Watchlist only'),
                          selected: _watchlistOnly,
                          onSelected: (v) => setState(() => _watchlistOnly = v),
                        ),
                      ],
                    ),
                  ),
                  const SectionHeader('Results announced'),
                  ...feed.when(
                    loading: () => [
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: loading,
                      ),
                    ],
                    error: (e, s) => [asyncError(e, s)],
                    data: (items) {
                      final list = items.where((i) => keep(i.symbol)).toList();
                      if (list.isEmpty) {
                        return [
                          const EmptyState(
                            icon: Icons.hourglass_empty,
                            message: 'No results announced yet today.',
                          ),
                        ];
                      }
                      return list.map((i) => _FeedCard(i)).toList();
                    },
                  ),
                  const SectionHeader('Concalls today'),
                  ...calendar.when(
                    loading: () => [const SizedBox.shrink()],
                    error: (e, s) => [asyncError(e, s)],
                    data: (days) {
                      final today = days.where(
                        (d) => dateId(d.date) == todayId,
                      );
                      final calls = today
                          .expand((d) => d.events)
                          .where(
                            (e) =>
                                e.type == EventType.concall && keep(e.symbol),
                          )
                          .toList();
                      if (calls.isEmpty) {
                        return [
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Text('No concalls scheduled today.'),
                          ),
                        ];
                      }
                      return calls
                          .map(
                            (e) => ListTile(
                              leading: const Icon(Icons.call),
                              title: Text(e.name),
                              subtitle: Text(e.note ?? 'Earnings call'),
                              trailing: Text(e.time ?? ''),
                              onTap: () => context.push(
                                '/company/${Uri.encodeComponent(e.symbol)}',
                              ),
                            ),
                          )
                          .toList();
                    },
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedCard extends StatelessWidget {
  const _FeedCard(this.item);
  final FeedItem item;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () =>
            context.push('/company/${Uri.encodeComponent(item.symbol)}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  WatchButton(item.symbol),
                ],
              ),
              Text(
                '${item.symbol} · ${item.period}'
                '${item.announcedAt == null ? '' : ' · ${timeFormat.format(item.announcedAt!)}'}',
                style: t.bodySmall,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _Metric(
                      'Revenue',
                      crore(item.revenue),
                      item.revenueYoY,
                    ),
                  ),
                  Expanded(
                    child: _Metric('Net profit', crore(item.pat), item.patYoY),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.yoy);
  final String label;
  final String value;
  final double? yoy;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      GrowthChip(yoy, label: 'YoY'),
    ],
  );
}
