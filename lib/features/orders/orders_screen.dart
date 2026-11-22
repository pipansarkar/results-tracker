import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import '../company/events_tab.dart' show OrderTile;

enum _Sort { latest, biggest, impact }

/// Order wins across the market (last ~30 days).
class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  _Sort _sort = _Sort.latest;
  bool _watchOnly = false;

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(ordersProvider);
    final watch = ref.watch(watchlistProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Order wins')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final (s, label) in const [
                  (_Sort.latest, 'Latest'),
                  (_Sort.biggest, 'Biggest ₹'),
                  (_Sort.impact, 'Biggest vs revenue'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _sort == s,
                      onSelected: (_) => setState(() => _sort = s),
                    ),
                  ),
                FilterChip(
                  label: const Text('Watchlists'),
                  selected: _watchOnly,
                  onSelected: (v) => setState(() => _watchOnly = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: orders.when(
              loading: () => loading,
              error: asyncError,
              data: (all) {
                final list = all
                    .where((o) => !_watchOnly || watch.contains(o.symbol))
                    .toList();
                switch (_sort) {
                  case _Sort.biggest:
                    list.sort(
                      (a, b) =>
                          (b.item.valueCr ?? 0).compareTo(a.item.valueCr ?? 0),
                    );
                  case _Sort.impact:
                    list.sort(
                      (a, b) => (b.item.pctRevenue ?? 0).compareTo(
                        a.item.pctRevenue ?? 0,
                      ),
                    );
                  case _Sort.latest:
                    list.sort((a, b) => b.item.date.compareTo(a.item.date));
                }
                if (list.isEmpty) {
                  return const EmptyState(
                    icon: Icons.assignment_outlined,
                    message: 'No order wins yet.',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(ordersProvider),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: list.length,
                    itemBuilder: (_, i) => InkWell(
                      onTap: () => context.push(
                        '/company/${Uri.encodeComponent(list[i].symbol)}',
                      ),
                      child: OrderTile(list[i].item, company: list[i].name),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
