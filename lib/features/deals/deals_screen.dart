import 'package:flutter/material.dart';
import '../../core/i18n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import '../company/ownership_tab.dart' show ActivityTile;

enum _Kind { all, block, bulk, sast, promoter }

/// Market-wide bulk/block deals and stake changes of the last few days.
class DealsScreen extends ConsumerStatefulWidget {
  const DealsScreen({super.key});

  @override
  ConsumerState<DealsScreen> createState() => _DealsScreenState();
}

class _DealsScreenState extends ConsumerState<DealsScreen> {
  _Kind _kind = _Kind.all;
  bool _hideIntraday = true;
  bool _watchOnly = false;

  @override
  Widget build(BuildContext context) {
    final deals = ref.watch(marketDealsProvider);
    final watch = ref.watch(watchlistProvider);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Big deals'))),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final k in _Kind.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(switch (k) {
                        _Kind.all => 'All',
                        _Kind.block => 'Block',
                        _Kind.bulk => 'Bulk',
                        _Kind.sast => 'Stake changes',
                        _Kind.promoter => 'Promoters',
                      }),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                  ),
                FilterChip(
                  label: Text(tr('Watchlist')),
                  selected: _watchOnly,
                  onSelected: (v) => setState(() => _watchOnly = v),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(tr('Hide intraday')),
                  selected: _hideIntraday,
                  onSelected: (v) => setState(() => _hideIntraday = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: deals.when(
              loading: () => loading,
              error: asyncError,
              data: (all) {
                final list = all.where((d) {
                  final a = d.item;
                  if (_hideIntraday && a.intraday) return false;
                  if (_watchOnly && !watch.contains(d.symbol)) return false;
                  return switch (_kind) {
                    _Kind.all => true,
                    _Kind.block => a.kind == 'block',
                    _Kind.bulk => a.kind == 'bulk',
                    _Kind.sast => a.kind == 'sast' || a.kind == 'insider',
                    _Kind.promoter => a.promoter,
                  };
                }).toList();
                if (list.isEmpty) {
                  return EmptyState(
                    icon: Icons.handshake_outlined,
                    message: tr('No deals match.'),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(marketDealsProvider),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    itemCount: list.length,
                    itemBuilder: (_, i) => InkWell(
                      onTap: () => context.push(
                        '/company/${Uri.encodeComponent(list[i].symbol)}',
                      ),
                      child: ActivityTile(list[i].item, company: list[i].name),
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
