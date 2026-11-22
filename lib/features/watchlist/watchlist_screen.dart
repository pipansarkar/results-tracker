import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// Several named watchlists. Pick a list with the chips at the top.
class WatchlistScreen extends ConsumerStatefulWidget {
  const WatchlistScreen({super.key});

  @override
  ConsumerState<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends ConsumerState<WatchlistScreen> {
  String? _selected;

  Future<void> _create() async {
    final name = await promptText(
      context,
      'New watchlist',
      'e.g. Defence, Banks, Long term',
    );
    if (name != null &&
        await ref.read(watchlistsProvider.notifier).create(name)) {
      setState(() => _selected = name.trim());
    }
  }

  Future<void> _manage(String name) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text('Rename "$name"'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text('Delete "$name"'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    final n = ref.read(watchlistsProvider.notifier);
    if (action == 'rename') {
      final to = await promptText(
        context,
        'Rename watchlist',
        'Name',
        initial: name,
      );
      if (to != null && await n.rename(name, to))
        setState(() => _selected = to.trim());
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete "$name"?'),
          content: const Text('The stocks stay in your other lists.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok == true) {
        await n.delete(name);
        setState(() => _selected = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(watchlistsProvider);
    final name = (_selected != null && lists.containsKey(_selected))
        ? _selected!
        : lists.keys.first;
    final symbols = lists[name] ?? const [];
    final push = ref.watch(firebaseEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watchlists'),
        actions: [
          if (symbols.isNotEmpty)
            IconButton(
              tooltip: 'Weekly report',
              icon: const Icon(Icons.summarize_outlined),
              onPressed: () =>
                  context.push('/weekly?list=${Uri.encodeComponent(name)}'),
            ),
          if (symbols.length >= 2)
            IconButton(
              tooltip: 'Compare this list',
              icon: const Icon(Icons.compare_arrows),
              onPressed: () => context.push(
                '/compare?s=${symbols.take(4).map(Uri.encodeComponent).join(',')}',
              ),
            ),
          IconButton(
            tooltip: 'Add a stock',
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: Column(
        children: [
          const SampleDataBanner(),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final e in lists.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: () => _manage(e.key),
                      child: ChoiceChip(
                        label: Text('${e.key} (${e.value.length})'),
                        selected: e.key == name,
                        onSelected: (_) => setState(() => _selected = e.key),
                      ),
                    ),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('New list'),
                  onPressed: _create,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    push
                        ? 'Alerts for results, concalls, orders, deals and red flags.'
                        : 'Push alerts start working once Firebase is connected.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Rename or delete this list',
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => _manage(name),
                ),
              ],
            ),
          ),
          Expanded(
            child: symbols.isEmpty
                ? EmptyState(
                    icon: Icons.star_border,
                    message:
                        '"$name" is empty. Add stocks to get alerts for results and concalls.',
                    action: FilledButton.icon(
                      onPressed: () => context.push('/search'),
                      icon: const Icon(Icons.search),
                      label: const Text('Find a stock'),
                    ),
                  )
                : ListView(
                    children: [for (final s in symbols) _WatchTile(s, name)],
                  ),
          ),
        ],
      ),
    );
  }
}

class _WatchTile extends ConsumerWidget {
  const _WatchTile(this.symbol, this.list);
  final String symbol;
  final String list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = ref.watch(companyProvider(symbol));
    final m = ref.watch(metricsProvider(symbol));
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
                if (m?.pe != null) Text('P/E ${m!.pe!.toStringAsFixed(1)}'),
              ],
            ),
          ),
          AsyncLoading() => const Text('Loading…'),
          _ => const Text('No results yet'),
        },
        trailing: IconButton(
          tooltip: 'Remove from $list',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: () =>
              ref.read(watchlistsProvider.notifier).toggle(symbol, list: list),
        ),
      ),
    );
  }
}
