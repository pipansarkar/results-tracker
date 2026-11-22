import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

class WatchlistScreen extends ConsumerWidget {
  const WatchlistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final symbols = ref.watch(watchlistProvider);
    final push = ref.watch(firebaseEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Watchlist'),
        actions: [
          if (symbols.length >= 2)
            IconButton(
              tooltip: 'Compare watchlist',
              icon: const Icon(Icons.compare_arrows),
              onPressed: () => context.push(
                '/compare?s=${symbols.take(4).map(Uri.encodeComponent).join(',')}',
              ),
            ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: Column(
        children: [
          const SampleDataBanner(),
          const StockSearchBar(),
          if (symbols.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                push
                    ? 'You get alerts when results are out, before concalls and when summaries are ready.'
                    : 'Push alerts start working once Firebase is connected.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: symbols.isEmpty
                ? EmptyState(
                    icon: Icons.star_border,
                    message:
                        'Add stocks to get alerts for results and concalls.',
                    action: FilledButton.icon(
                      onPressed: () => context.push('/search'),
                      icon: const Icon(Icons.search),
                      label: Text('Find a stock'),
                    ),
                  )
                : ListView(children: [for (final s in symbols) _WatchTile(s)]),
          ),
        ],
      ),
    );
  }
}

class _WatchTile extends ConsumerWidget {
  const _WatchTile(this.symbol);
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = ref.watch(companyProvider(symbol));
    return Card(
      child: ListTile(
        onTap: () => context.push('/company/${Uri.encodeComponent(symbol)}'),
        title: Text(company.value?.name ?? symbol),
        subtitle: switch (company) {
          AsyncData(value: final Company c) when c.latest != null => Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text('${c.latest!.period} · Rev ${crore(c.latest!.revenue)}'),
                GrowthChip(
                  pctChange(c.latest!.revenue, c.yearAgoQuarter?.revenue),
                  label: 'YoY',
                ),
                GrowthChip(
                  pctChange(c.latest!.pat, c.yearAgoQuarter?.pat),
                  label: 'PAT',
                ),
              ],
            ),
          ),
          AsyncLoading() => Text('Loading…'),
          _ => Text('No results yet'),
        },
        trailing: WatchButton(symbol),
      ),
    );
  }
}
