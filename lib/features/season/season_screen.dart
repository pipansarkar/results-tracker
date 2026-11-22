import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import '../company/section.dart';

/// Results-season scoreboard: how many reported, who grew, sector heatmap,
/// best/worst results and the biggest share-price reactions.
class SeasonScreen extends ConsumerWidget {
  const SeasonScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final season = ref.watch(seasonProvider);
    final names = {
      for (final c
          in ref.watch(companiesProvider).value ?? const <CompanyLite>[])
        c.symbol: c.name,
    };
    return Scaffold(
      appBar: AppBar(title: Text('Results season')),
      body: season.when(
        loading: () => loading,
        error: asyncError,
        data: (s) => s == null
            ? EmptyState(
                icon: Icons.scoreboard_outlined,
                message:
                    'The scoreboard appears once enough companies have reported.',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  const SampleDataBanner(),
                  _Header(s),
                  if (s.sectors.isNotEmpty)
                    Section(
                      title: 'Sectors (median YoY growth)',
                      child: _Sectors(s.sectors),
                    ),
                  Section(
                    title: 'Biggest profit growth',
                    child: _List(s.topProfit, names, valueKey: 'pg'),
                  ),
                  Section(
                    title: 'Biggest profit falls',
                    child: _List(s.worstProfit, names, valueKey: 'pg'),
                  ),
                  if (s.bestReaction.isNotEmpty)
                    Section(
                      title: 'Market loved these results',
                      child: _List(
                        s.bestReaction,
                        names,
                        valueKey: 'r',
                        label: 'Price',
                      ),
                    ),
                  if (s.worstReaction.isNotEmpty)
                    Section(
                      title: 'Market disliked these results',
                      child: _List(
                        s.worstReaction,
                        names,
                        valueKey: 'r',
                        label: 'Price',
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Text(
                      'Growth is year-on-year for the quarter. Biggest movers include only '
                      'companies above ₹1,000 Cr market cap. Price reaction = share move on '
                      'the first trading session after the result.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.s);
  final Season s;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = s.total > 0 ? s.reported / s.total : 0.0;
    Widget stat(String label, String value, {Color? color}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${s.season} season',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text('${s.reported} of ${s.total} companies have reported'),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: progress, minHeight: 8),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                stat(
                  'Grew revenue',
                  s.revGrewPct == null ? '—' : '${s.revGrewPct!.round()}%',
                ),
                stat(
                  'Grew profit',
                  s.profitGrewPct == null
                      ? '—'
                      : '${s.profitGrewPct!.round()}%',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                stat(
                  'Median revenue growth',
                  pct(s.medianRevGrowth),
                  color: (s.medianRevGrowth ?? 0) >= 0 ? gainColor : lossColor,
                ),
                stat(
                  'Median profit growth',
                  pct(s.medianProfitGrowth),
                  color: (s.medianProfitGrowth ?? 0) >= 0
                      ? gainColor
                      : lossColor,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Sectors extends StatelessWidget {
  const _Sectors(this.rows);
  final List<Map<String, dynamic>> rows;

  Color _heat(double? v) {
    if (v == null) return Colors.grey.withValues(alpha: 0.15);
    final t = (v.clamp(-30, 30) / 30).abs().toDouble();
    return (v >= 0 ? gainColor : lossColor).withValues(alpha: 0.12 + 0.5 * t);
  }

  @override
  Widget build(BuildContext context) {
    double? n(dynamic v) => v == null ? null : (v as num).toDouble();
    return Column(
      children: [
        Row(
          children: [
            const Expanded(child: SizedBox()),
            for (final h in ['Revenue', 'Profit'])
              SizedBox(
                width: 72,
                child: Text(
                  h,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
          ],
        ),
        for (final r in rows.take(25))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${r['sector']} (${r['n']})',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                for (final k in ['rg', 'pg'])
                  Container(
                    width: 68,
                    margin: const EdgeInsets.only(left: 4),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: _heat(n(r[k])),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      pct(n(r[k])),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _List extends StatelessWidget {
  const _List(
    this.rows,
    this.names, {
    required this.valueKey,
    this.label = 'Profit',
  });
  final List<Map<String, dynamic>> rows;
  final Map<String, String> names;
  final String valueKey;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return Text('Not enough data yet.');
    return Column(
      children: [
        for (final r in rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              names[r['s']] ?? r['s'] as String,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(r['s'] as String),
            trailing: GrowthChip(
              (r[valueKey] as num?)?.toDouble(),
              label: label,
            ),
            onTap: () => context.push(
              '/company/${Uri.encodeComponent(r['s'] as String)}',
            ),
          ),
      ],
    );
  }
}
