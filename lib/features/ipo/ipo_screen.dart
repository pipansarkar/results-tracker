import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import '../company/section.dart';

/// IPOs: open now, upcoming, and recently listed.
class IpoScreen extends ConsumerWidget {
  const IpoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(iposProvider);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('IPOs'),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Open now (${board.value?.open.length ?? 0})'),
              Tab(text: 'Upcoming (${board.value?.upcoming.length ?? 0})'),
              const Tab(text: 'Listed'),
            ],
          ),
        ),
        body: board.when(
          loading: () => loading,
          error: asyncError,
          data: (b) => TabBarView(
            children: [
              _List(b.open, empty: 'No IPOs open for bidding right now.'),
              _List(b.upcoming, empty: 'No upcoming IPOs announced yet.'),
              _List(b.listed, empty: 'No IPOs listed in the last 45 days.'),
            ],
          ),
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List(this.items, {required this.empty});
  final List<Ipo> items;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty)
      return EmptyState(icon: Icons.rocket_launch_outlined, message: empty);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [for (final i in items) _IpoCard(i)],
    );
  }
}

String _dateRange(Ipo i) {
  if (i.open == null || i.close == null) return '';
  return '${dayFormat.format(i.open!)} – ${dayFormat.format(i.close!)}';
}

class _IpoCard extends StatelessWidget {
  const _IpoCard(this.i);
  final Ipo i;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final listed = i.status == 'listed';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: listed
            ? () => context.push('/company/${Uri.encodeComponent(i.symbol)}')
            : () => context.push('/ipo/${Uri.encodeComponent(i.symbol)}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      i.name,
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _Tag(
                    i.sme ? 'SME' : 'Main board',
                    i.sme ? Colors.deepPurple : Colors.blue,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  i.symbol,
                  if (!listed && _dateRange(i).isNotEmpty) _dateRange(i),
                  if (listed && i.listingDate != null)
                    'Listed ${dayFormat.format(i.listingDate!)}',
                ].join(' · '),
                style: t.bodySmall,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  if ((i.priceBand ?? '').isNotEmpty && !listed)
                    _Kv('Price band', i.priceBand!.replaceAll('Rs.', '₹')),
                  if (i.infoValue('Bid Lot') != null)
                    _Kv(
                      'Lot',
                      i.infoValue('Bid Lot')!.split(' ').take(2).join(' '),
                    ),
                  if (i.totalTimes != null)
                    _Kv(
                      'Subscribed',
                      '${i.totalTimes!.toStringAsFixed(2)}x',
                      color: i.totalTimes! >= 1 ? gainColor : null,
                    ),
                  if (listed && i.issuePrice != null)
                    _Kv('Issue price', '₹${i.issuePrice!.toStringAsFixed(0)}'),
                  if (listed && i.listingGain != null)
                    _Kv(
                      'Listing gain',
                      pct(i.listingGain),
                      color: i.listingGain! >= 0 ? gainColor : lossColor,
                    ),
                  if (listed && i.gainSinceIssue != null)
                    _Kv(
                      'Since issue',
                      pct(i.gainSinceIssue),
                      color: i.gainSinceIssue! >= 0 ? gainColor : lossColor,
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

class _Kv extends StatelessWidget {
  const _Kv(this.k, this.v, {this.color});
  final String k, v;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(k, style: Theme.of(context).textTheme.labelSmall),
      Text(
        v,
        style: TextStyle(fontWeight: FontWeight.w700, color: color),
      ),
    ],
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

/// Full details of one open / upcoming IPO.
class IpoDetailScreen extends ConsumerWidget {
  const IpoDetailScreen({super.key, required this.symbol});
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(iposProvider);
    return Scaffold(
      appBar: AppBar(title: Text(symbol)),
      body: board.when(
        loading: () => loading,
        error: asyncError,
        data: (b) {
          final i = [
            ...b.open,
            ...b.upcoming,
            ...b.listed,
          ].where((x) => x.symbol == symbol).firstOrNull;
          if (i == null) {
            return const EmptyState(
              icon: Icons.search_off,
              message: 'IPO not found.',
            );
          }
          final t = Theme.of(context).textTheme;
          final cats = i.subscription.where((s) => s.times != null).toList();
          final maxT = cats.fold<double>(
            1,
            (a, s) => s.times! > a ? s.times! : a,
          );
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Card(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.35),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        i.name,
                        style: t.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          _Tag(
                            i.sme ? 'SME' : 'Main board',
                            i.sme ? Colors.deepPurple : Colors.blue,
                          ),
                          _Tag(
                            i.status == 'open'
                                ? 'Open now'
                                : i.status == 'upcoming'
                                ? 'Upcoming'
                                : 'Listed',
                            i.status == 'open' ? gainColor : Colors.grey,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 20,
                        runSpacing: 10,
                        children: [
                          if (_dateRange(i).isNotEmpty)
                            _Kv('Bidding', _dateRange(i)),
                          if ((i.priceBand ?? '').isNotEmpty)
                            _Kv(
                              'Price band',
                              i.priceBand!.replaceAll('Rs.', '₹'),
                            ),
                          if (i.totalTimes != null)
                            _Kv(
                              'Subscribed',
                              '${i.totalTimes!.toStringAsFixed(2)}x',
                              color: i.totalTimes! >= 1 ? gainColor : null,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (cats.isNotEmpty)
                Section(
                  title: 'Subscription by category',
                  trailing: i.subscriptionAsOf == null
                      ? null
                      : Text(i.subscriptionAsOf!, style: t.bodySmall),
                  child: Column(
                    children: [
                      for (final s in cats)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      s.category,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  Text(
                                    '${s.times!.toStringAsFixed(2)}x',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: s.times! >= 1 ? gainColor : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: (s.times! / maxT).clamp(0, 1),
                                  minHeight: 8,
                                  color: s.times! >= 1
                                      ? gainColor
                                      : Colors.amber.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              if (i.info.isNotEmpty)
                Section(
                  title: 'Issue details',
                  child: Column(
                    children: [
                      for (final (k, v) in i.info.where(
                        (r) => r.$1.isNotEmpty && r.$2.isNotEmpty,
                      ))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 130,
                                child: Text(
                                  k,
                                  style: t.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  v,
                                  style: const TextStyle(height: 1.35),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Text(
                  'From NSE. Subscription updates during the bidding period. '
                  'Information only, not a recommendation to apply.',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
