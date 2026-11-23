import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

enum _Filter { all, watchlist, profitUp, profitDown, movers }

const _filterLabels = {
  _Filter.all: 'All',
  _Filter.watchlist: 'Watchlist',
  _Filter.profitUp: 'Profit up',
  _Filter.profitDown: 'Profit down',
  _Filter.movers: 'Biggest movers',
};

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  _Filter _filter = _Filter.all;

  List<FeedItem> _apply(List<FeedItem> items, Set<String> watch) {
    final list = switch (_filter) {
      _Filter.all => [...items],
      _Filter.watchlist =>
        items.where((i) => watch.contains(i.symbol)).toList(),
      _Filter.profitUp => items.where((i) => (i.patYoY ?? 0) > 0).toList(),
      _Filter.profitDown => items.where((i) => (i.patYoY ?? 0) < 0).toList(),
      _Filter.movers => items.where((i) => i.reaction != null).toList(),
    };
    switch (_filter) {
      case _Filter.profitUp:
        list.sort((a, b) => (b.patYoY ?? 0).compareTo(a.patYoY ?? 0));
      case _Filter.profitDown:
        list.sort((a, b) => (a.patYoY ?? 0).compareTo(b.patYoY ?? 0));
      case _Filter.movers:
        list.sort((a, b) => b.reaction!.abs().compareTo(a.reaction!.abs()));
      default:
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(todayFeedProvider);
    final calendar = ref.watch(calendarProvider);
    final watch = ref.watch(watchlistProvider).toSet();
    final now = DateTime.now();
    final todayId = dateId(now);
    final todayCalls = [
      for (final d in calendar.value ?? const <CalendarDay>[])
        if (dateId(d.date) == todayId)
          for (final e in d.events)
            if (e.type == EventType.concall) e,
    ];
    final items = feed.value ?? const <FeedItem>[];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Today's Results"),
            Text(
              '${_greeting(now)} · ${dayFormat.format(now)}',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(todayFeedProvider);
          ref.invalidate(calendarProvider);
          ref.invalidate(seasonProvider);
          ref.invalidate(ordersProvider);
          ref.invalidate(iposProvider);
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const SampleDataBanner(),
            const StockSearchBar(),
            _Hero(
              results: items.length,
              concalls: todayCalls.length,
              nextWeek: [
                for (final d in calendar.value ?? const <CalendarDay>[])
                  if (d.date.isAfter(now) &&
                      d.date.isBefore(now.add(const Duration(days: 7))))
                    for (final e in d.events)
                      if (e.type == EventType.results) e,
              ].length,
            ),
            const _QuickActions(),
            _WatchlistToday(
              results: items.where((i) => watch.contains(i.symbol)).toList(),
              calls: todayCalls.where((e) => watch.contains(e.symbol)).toList(),
            ),
            SectionHeader(
              'Results announced',
              trailing: items.isEmpty
                  ? null
                  : Text(
                      '${items.length} today',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
            ),
            if (items.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  children: [
                    for (final f in _Filter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(_filterLabels[f]!),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                      ),
                  ],
                ),
              ),
            ...feed.when(
              loading: () => [
                const Padding(padding: EdgeInsets.all(24), child: loading),
              ],
              error: (e, s) => [asyncError(e, s)],
              data: (all) {
                final list = _apply(all, watch);
                if (list.isEmpty) {
                  return [
                    EmptyState(
                      icon: Icons.hourglass_empty,
                      message: all.isEmpty
                          ? 'No results announced yet today.\n'
                                'They appear here within minutes of filing.'
                          : 'Nothing matches "${_filterLabels[_filter]}".',
                    ),
                  ];
                }
                return [for (final i in list) _FeedCard(i)];
              },
            ),
            SectionHeader(
              'Concalls today',
              trailing: TextButton(
                onPressed: () => context.go('/calendar'),
                child: const Text('Calendar'),
              ),
            ),
            if (todayCalls.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('No concalls scheduled today.'),
              )
            else
              Card(
                child: Column(
                  children: [
                    for (final e in todayCalls)
                      ListTile(
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.tertiaryContainer,
                          child: const Icon(Icons.call, size: 18),
                        ),
                        title: Text(e.name),
                        subtitle: Text(e.note ?? 'Earnings call'),
                        trailing: Text(
                          e.time ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        onTap: () => context.push(
                          '/company/${Uri.encodeComponent(e.symbol)}',
                        ),
                      ),
                  ],
                ),
              ),
            _ComingUp(days: calendar.value ?? const []),
            const _OrdersAndIpos(),
          ],
        ),
      ),
    );
  }

  static String _greeting(DateTime t) => t.hour < 12
      ? 'Good morning'
      : t.hour < 17
      ? 'Good afternoon'
      : 'Good evening';
}

// --------------------------------------------------------------------- hero

class _Hero extends ConsumerWidget {
  const _Hero({
    required this.results,
    required this.concalls,
    required this.nextWeek,
  });
  final int results, concalls, nextWeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(seasonProvider).value;
    final scheme = Theme.of(context).colorScheme;
    final on = scheme.onPrimary;
    final dim = on.withValues(alpha: 0.85);
    final progress = s == null || s.total == 0 ? null : s.reported / s.total;
    Widget stat(String value, String label, {double size = 22}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              color: on,
              fontSize: size,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(label, style: TextStyle(color: dim, fontSize: 12)),
        ],
      ),
    );
    String p0(double? v) => v == null ? '—' : '${v.round()}%';

    // Highlights: best / weakest sector, biggest profit jump, best reaction.
    final chips = <(IconData, String, String?)>[];
    if (s != null) {
      final secs = s.sectors.where((x) => x['pg'] != null).toList();
      if (secs.isNotEmpty) {
        final best = secs.first, worst = secs.last;
        chips.add((
          Icons.emoji_events_outlined,
          'Best sector: ${best['sector']} ${pct((best['pg'] as num).toDouble())}',
          null,
        ));
        if (secs.length > 1) {
          chips.add((
            Icons.trending_down,
            'Weakest: ${worst['sector']} ${pct((worst['pg'] as num).toDouble())}',
            null,
          ));
        }
      }
      if (s.topProfit.isNotEmpty) {
        final t = s.topProfit.first;
        chips.add((
          Icons.rocket_launch_outlined,
          'Top profit jump: ${t['s']} ${pct((t['pg'] as num?)?.toDouble())}',
          t['s'] as String,
        ));
      }
      if (s.bestReaction.isNotEmpty) {
        final t = s.bestReaction.first;
        chips.add((
          Icons.show_chart,
          'Best stock reaction: ${t['s']} ${pct((t['r'] as num?)?.toDouble())}',
          t['s'] as String,
        ));
      }
      if (s.worstProfit.isNotEmpty) {
        final t = s.worstProfit.first;
        chips.add((
          Icons.warning_amber_rounded,
          'Biggest profit fall: ${t['s']} ${pct((t['pg'] as num?)?.toDouble())}',
          t['s'] as String,
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.primary,
                Color.lerp(scheme.primary, scheme.tertiary, 0.6)!,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => context.push('/season'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.scoreboard_outlined, color: on, size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              s == null
                                  ? 'Results season'
                                  : '${periodLabel(s.season)} results season',
                              style: TextStyle(
                                color: on,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            'Scoreboard',
                            style: TextStyle(color: dim, fontSize: 12),
                          ),
                          Icon(Icons.chevron_right, color: on),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          stat('$results', 'results today'),
                          stat('$concalls', 'concalls today'),
                          stat('$nextWeek', 'due next 7 days'),
                        ],
                      ),
                      if (s != null) ...[
                        const SizedBox(height: 12),
                        Divider(height: 1, color: on.withValues(alpha: 0.2)),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            stat(p0(s.profitGrewPct), 'grew profit', size: 18),
                            stat(p0(s.revGrewPct), 'grew revenue', size: 18),
                            stat(
                              s.medianProfitGrowth == null
                                  ? '—'
                                  : pct(s.medianProfitGrowth),
                              'median profit gr.',
                              size: 18,
                            ),
                          ],
                        ),
                      ],
                      if (progress != null) ...[
                        const SizedBox(height: 14),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress.clamp(0, 1),
                            minHeight: 6,
                            color: on,
                            backgroundColor: on.withValues(alpha: 0.25),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${s!.reported} of ${s.total} companies reported '
                          '(${(progress * 100).round()}%)'
                          '${s.medianRevGrowth == null ? '' : ' · median revenue ${pct(s.medianRevGrowth)}'}',
                          style: TextStyle(color: dim, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (chips.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    children: [
                      for (final (icon, text, sym) in chips)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Material(
                            color: on.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(20),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => context.push(
                                sym == null
                                    ? '/season'
                                    : '/company/${Uri.encodeComponent(sym)}',
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(icon, size: 15, color: on),
                                    const SizedBox(width: 6),
                                    Text(
                                      text,
                                      style: TextStyle(
                                        color: on,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ quick actions

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actions = <(IconData, String, VoidCallback)>[
      (Icons.filter_alt_outlined, 'Screener', () => context.go('/screener')),
      (
        Icons.calendar_month_outlined,
        'Calendar',
        () => context.go('/calendar'),
      ),
      (
        Icons.assignment_turned_in_outlined,
        'Orders',
        () => context.push('/orders'),
      ),
      (Icons.rocket_launch_outlined, 'IPOs', () => context.push('/ipos')),
      (Icons.handshake_outlined, 'Deals', () => context.push('/deals')),
      (Icons.leaderboard_outlined, 'Season', () => context.push('/season')),
      (Icons.compare_arrows, 'Compare', () => context.push('/compare')),
      (Icons.star_outline, 'Watchlists', () => context.go('/watchlist')),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / 4;
          return Wrap(
            children: [
              for (final (icon, label, onTap) in actions)
                SizedBox(
                  width: w,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer.withValues(
                                alpha: 0.6,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(icon, color: scheme.onPrimaryContainer),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            label,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// --------------------------------------------------------- watchlist today

class _WatchlistToday extends StatelessWidget {
  const _WatchlistToday({required this.results, required this.calls});
  final List<FeedItem> results;
  final List<CalendarEvent> calls;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty && calls.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.star, size: 18, color: Colors.amber),
                const SizedBox(width: 6),
                Text(
                  'Your watchlist today',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            for (final r in results)
              _line(
                context,
                Icons.receipt_long_outlined,
                '${r.symbol} ${r.period}: profit ${pct(r.patYoY)} YoY',
                r.symbol,
                color: r.patYoY == null
                    ? null
                    : (r.patYoY! >= 0 ? gainColor : lossColor),
              ),
            for (final c in calls)
              _line(
                context,
                Icons.call_outlined,
                '${c.symbol}: concall${c.time == null ? ' today' : ' at ${c.time}'}',
                c.symbol,
              ),
          ],
        ),
      ),
    );
  }

  Widget _line(
    BuildContext context,
    IconData icon,
    String text,
    String symbol, {
    Color? color,
  }) => InkWell(
    onTap: () => context.push('/company/${Uri.encodeComponent(symbol)}'),
    child: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

// --------------------------------------------------------------- feed card

class _FeedCard extends StatelessWidget {
  const _FeedCard(this.item);
  final FeedItem item;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final edge = item.patYoY == null
        ? Colors.grey
        : (item.patYoY! >= 0 ? gainColor : lossColor);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            context.push('/company/${Uri.encodeComponent(item.symbol)}'),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: edge),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  style: t.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${item.symbol} · ${periodLabel(item.period)}'
                                  '${item.announcedAt == null ? '' : ' · ${timeFormat.format(item.announcedAt!)}'}',
                                  style: t.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (item.reaction != null) _Reaction(item.reaction!),
                          WatchButton(item.symbol),
                        ],
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
                            child: _Metric(
                              'Net profit',
                              crore(item.pat),
                              item.patYoY,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Reaction extends StatelessWidget {
  const _Reaction(this.v);
  final double v;

  @override
  Widget build(BuildContext context) {
    final c = v >= 0 ? gainColor : lossColor;
    return Tooltip(
      message: 'Share price move after the results',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              v >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
              size: 13,
              color: c,
            ),
            Text(
              pct(v.abs()).replaceAll('+', ''),
              style: TextStyle(
                color: c,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
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
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      if (yoy != null) ...[
        const SizedBox(height: 4),
        GrowthChip(yoy, label: 'YoY'),
      ],
    ],
  );
}

// --------------------------------------------------------------- coming up

class _ComingUp extends StatelessWidget {
  const _ComingUp({required this.days});
  final List<CalendarDay> days;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final next = days
        .where((d) => d.date.isAfter(today) && d.events.isNotEmpty)
        .take(5)
        .toList();
    if (next.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Coming up'),
        SizedBox(
          height: 112,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final d in next)
                Builder(
                  builder: (context) {
                    final results = d.events
                        .where((e) => e.type == EventType.results)
                        .toList();
                    final calls = d.events
                        .where((e) => e.type == EventType.concall)
                        .length;
                    final diff = d.date.difference(today).inDays;
                    return SizedBox(
                      width: 168,
                      child: Card(
                        margin: const EdgeInsets.only(right: 8, bottom: 4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => context.go('/calendar'),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  diff == 1
                                      ? 'Tomorrow'
                                      : dayFormat.format(d.date),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: scheme.primary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${results.length} result${results.length == 1 ? '' : 's'} · $calls concall${calls == 1 ? '' : 's'}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                const Spacer(),
                                Text(
                                  results
                                      .take(3)
                                      .map((e) => e.symbol)
                                      .join(', '),
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------ order wins & IPOs

class _OrdersAndIpos extends ConsumerWidget {
  const _OrdersAndIpos();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = [...?ref.watch(ordersProvider).value]
      ..sort((a, b) => b.item.date.compareTo(a.item.date));
    final ipos = ref.watch(iposProvider).value;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Order wins',
          trailing: TextButton(
            onPressed: () => context.push('/orders'),
            child: const Text('See all'),
          ),
        ),
        if (orders.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Latest contracts won by companies appear here.'),
          )
        else
          Card(
            child: Column(
              children: [
                for (final o in orders.take(3))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.assignment_turned_in_outlined),
                    title: Text(o.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        dayFormat.format(o.item.date),
                        if (o.item.pctRevenue != null)
                          '${o.item.pctRevenue!.toStringAsFixed(1)}% of revenue',
                      ].join(' · '),
                    ),
                    trailing: Text(
                      o.item.valueCr == null ? '' : crore(o.item.valueCr),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    onTap: () => context.push(
                      '/company/${Uri.encodeComponent(o.symbol)}',
                    ),
                  ),
              ],
            ),
          ),
        SectionHeader(
          'IPOs',
          trailing: TextButton(
            onPressed: () => context.push('/ipos'),
            child: const Text('See all'),
          ),
        ),
        if (ipos == null || (ipos.open.isEmpty && ipos.upcoming.isEmpty))
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('No IPOs open or upcoming right now.'),
          )
        else
          Card(
            child: Column(
              children: [
                for (final i in [...ipos.open, ...ipos.upcoming].take(3))
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.rocket_launch_outlined,
                      color: i.status == 'open' ? gainColor : null,
                    ),
                    title: Text(i.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        i.status == 'open' ? 'Open now' : 'Upcoming',
                        if (i.sme) 'SME',
                        if ((i.priceBand ?? '').isNotEmpty)
                          i.priceBand!.replaceAll('Rs.', '₹'),
                      ].join(' · '),
                      style: t.bodySmall,
                    ),
                    trailing: i.totalTimes == null
                        ? null
                        : Text(
                            '${i.totalTimes!.toStringAsFixed(1)}x',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: i.totalTimes! >= 1 ? gainColor : null,
                            ),
                          ),
                    onTap: () =>
                        context.push('/ipo/${Uri.encodeComponent(i.symbol)}'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
