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
                          label: Text('Watchlist only'),
                          selected: _watchlistOnly,
                          onSelected: (v) => setState(() => _watchlistOnly = v),
                        ),
                      ],
                    ),
                  ),
                  const _SeasonCard(),
                  const _MoreCards(),
                  SectionHeader('Results announced'),
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
                          EmptyState(
                            icon: Icons.hourglass_empty,
                            message: 'No results announced yet today.',
                          ),
                        ];
                      }
                      return list.map((i) => _FeedCard(i)).toList();
                    },
                  ),
                  SectionHeader('Concalls today'),
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
                          Padding(
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
              if (item.story.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final b in item.story) StoryBadge(b)],
                ),
              ],
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
                  if (item.reaction != null)
                    Expanded(
                      child: _Metric(
                        'Share price',
                        item.reaction! >= 0 ? 'Up' : 'Down',
                        item.reaction,
                      ),
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

/// Results-season snapshot + entry points to the scoreboard and deals.
class _SeasonCard extends ConsumerWidget {
  const _SeasonCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(seasonProvider).value;
    final scheme = Theme.of(context).colorScheme;
    Widget card(
      IconData icon,
      String title,
      String sub,
      String route, {
      Color? color,
    }) => Expanded(
      child: Card(
        margin: EdgeInsets.zero,
        color: color,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => context.push(route),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  sub,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          card(
            Icons.scoreboard_outlined,
            s == null ? 'Results season' : '${s.season} season',
            s == null
                ? 'Scoreboard'
                : '${s.reported} reported · ${s.profitGrewPct?.round() ?? '—'}% grew profit',
            '/season',
            color: scheme.primaryContainer.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 8),
          card(
            Icons.handshake_outlined,
            'Big deals',
            'Bulk, block & stake changes',
            '/deals',
          ),
        ],
      ),
    );
  }
}

/// Second row: order wins and IPOs.
class _MoreCards extends ConsumerWidget {
  const _MoreCards();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ipos = ref.watch(iposProvider).value;
    final orders = ref.watch(ordersProvider).value;
    Widget card(IconData icon, String title, String sub, String route) =>
        Expanded(
          child: Card(
            margin: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => context.push(route),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(icon, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sub,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          card(
            Icons.assignment_turned_in_outlined,
            'Order wins',
            orders == null
                ? 'Latest contracts won'
                : '${orders.length} in the last 30 days',
            '/orders',
          ),
          const SizedBox(width: 8),
          card(
            Icons.rocket_launch_outlined,
            'IPOs',
            ipos == null
                ? 'Open, upcoming & listed'
                : '${ipos.open.length} open · ${ipos.upcoming.length} upcoming',
            '/ipos',
          ),
        ],
      ),
    );
  }
}
