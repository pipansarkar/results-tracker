import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

const _palette = [
  Color(0xFF2563EB),
  Color(0xFFDB2777),
  Color(0xFF059669),
  Color(0xFFF59E0B),
];

/// Rows of the comparison table, grouped.
const _groups = <(String, List<String>)>[
  ('Valuation', ['p', 'mc', 'pe', 'peg', 'pb', 'ev']),
  ('Returns & safety', ['roe', 'roce', 'de']),
  ('Growth', ['rg', 'pg', 'rgt', 'pgt']),
  ('Profitability', ['ebm', 'npm', 'eps', 'bv']),
  ('Size (TTM)', ['rev', 'pat']),
];

class CompareScreen extends ConsumerStatefulWidget {
  const CompareScreen({super.key, required this.initial});
  final List<String> initial;

  @override
  ConsumerState<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends ConsumerState<CompareScreen> {
  late final List<String> _symbols = widget.initial.take(4).toList();

  Future<void> _add() async {
    final picked = await context.push<String>('/search?pick=1');
    if (picked != null && !_symbols.contains(picked) && _symbols.length < 4) {
      setState(() => _symbols.add(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final screener = ref.watch(screenerProvider);
    final companies = ref.watch(companiesProvider).value ?? const [];
    final names = {for (final c in companies) c.symbol: c.name};
    final metrics = {
      for (final m in screener.value ?? const <StockMetrics>[]) m.symbol: m,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text('Compare'),
        actions: [
          if (_symbols.length < 4)
            TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: Text('Add stock'),
            ),
        ],
      ),
      body: _symbols.isEmpty
          ? EmptyState(
              icon: Icons.compare_arrows,
              message: 'Add 2 to 4 stocks to compare them side by side.',
              action: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: Text('Add stock'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                // Selected stocks
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < _symbols.length; i++)
                        InputChip(
                          avatar: CircleAvatar(
                            backgroundColor: _palette[i],
                            radius: 6,
                          ),
                          label: Text(names[_symbols[i]] ?? _symbols[i]),
                          onPressed: () => context.push(
                            '/company/${Uri.encodeComponent(_symbols[i])}',
                          ),
                          onDeleted: () => setState(() => _symbols.removeAt(i)),
                        ),
                    ],
                  ),
                ),
                if (_symbols.length == 1)
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Add at least one more stock to compare.'),
                  ),
                _Card(
                  title: 'Key numbers',
                  subtitle: 'Best value in each row is highlighted',
                  child: screener.isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: loading,
                        )
                      : _Table(symbols: _symbols, metrics: metrics),
                ),
                _Card(
                  title: 'Revenue growth',
                  subtitle: 'Quarterly revenue, oldest of the 8 quarters = 100',
                  child: _IndexedChart(
                    symbols: _symbols,
                    field: (q) => q.revenue,
                  ),
                ),
                _Card(
                  title: 'Profit growth',
                  subtitle: 'Quarterly profit, oldest of the 8 quarters = 100',
                  child: _IndexedChart(symbols: _symbols, field: (q) => q.pat),
                ),
                _Card(
                  title: 'EBITDA margin',
                  subtitle: 'Per quarter, %',
                  child: _IndexedChart(
                    symbols: _symbols,
                    field: (q) => q.ebitdaMargin,
                    indexed: false,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(disclaimerText, style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (subtitle != null)
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

class _Table extends StatelessWidget {
  const _Table({required this.symbols, required this.metrics});
  final List<String> symbols;
  final Map<String, StockMetrics> metrics;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final rows = <TableRow>[
      TableRow(
        children: [
          const SizedBox(),
          for (var i = 0; i < symbols.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                symbols[i],
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  color: _palette[i],
                ),
              ),
            ),
        ],
      ),
    ];
    for (final (group, keys) in _groups) {
      rows.add(
        TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                group.toUpperCase(),
                style: t.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final _ in symbols) const SizedBox(),
          ],
        ),
      );
      for (final k in keys) {
        final d = metricDef(k);
        final vals = [
          for (final s in symbols)
            metrics[s] == null ? null : d.get(metrics[s]!),
        ];
        final present = vals.whereType<double>().toList();
        // Best = max (or min); P/E-type ratios only count positive values.
        double? best;
        if (present.length >= 2 &&
            k != 'p' &&
            k != 'mc' &&
            k != 'rev' &&
            k != 'pat') {
          final pool = d.higherIsBetter
              ? present
              : present.where((v) => v > 0).toList();
          if (pool.isNotEmpty) {
            best = d.higherIsBetter
                ? pool.reduce((a, b) => a > b ? a : b)
                : pool.reduce((a, b) => a < b ? a : b);
          }
        }
        rows.add(
          TableRow(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
            children: [
              Tooltip(
                message: d.help,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(d.short, style: const TextStyle(fontSize: 13)),
                ),
              ),
              for (final v in vals)
                Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 4,
                  ),
                  margin: const EdgeInsets.symmetric(
                    vertical: 2,
                    horizontal: 2,
                  ),
                  decoration: v != null && v == best
                      ? BoxDecoration(
                          color: gainColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        )
                      : null,
                  child: FittedBox(
                    child: Text(
                      metricValue(v, d.unit),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: v != null && v == best
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: v != null && v == best ? gainColor : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }
    }
    return Table(
      columnWidths: {
        0: const FlexColumnWidth(1.3),
        for (var i = 1; i <= symbols.length; i++) i: const FlexColumnWidth(1),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: rows,
    );
  }
}

/// Multi-line chart of the last 8 quarters for each stock. Indexed mode
/// rebases each line to 100 so companies of very different size compare.
class _IndexedChart extends ConsumerWidget {
  const _IndexedChart({
    required this.symbols,
    required this.field,
    this.indexed = true,
  });
  final List<String> symbols;
  final double? Function(QuarterResult) field;
  final bool indexed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = <LineChartBarData>[];
    List<String> labels = const [];
    for (var i = 0; i < symbols.length; i++) {
      final c = ref.watch(companyProvider(symbols[i])).value;
      if (c == null || c.quarters.isEmpty) continue;
      final qs = c.quarters.take(8).toList().reversed.toList();
      if (qs.length > labels.length) labels = qs.map((q) => q.period).toList();
      final base = qs
          .map(field)
          .firstWhere((v) => v != null && v > 0, orElse: () => null);
      final spots = <FlSpot>[];
      for (var j = 0; j < qs.length; j++) {
        final v = field(qs[j]);
        if (v == null) continue;
        if (indexed) {
          if (base == null) continue;
          spots.add(FlSpot(j.toDouble(), v / base * 100));
        } else {
          spots.add(FlSpot(j.toDouble(), v));
        }
      }
      if (spots.isEmpty) continue;
      lines.add(
        LineChartBarData(
          spots: spots,
          color: _palette[i],
          barWidth: 2.5,
          isCurved: true,
          preventCurveOverShooting: true,
          dotData: const FlDotData(show: false),
        ),
      );
    }
    if (lines.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(16),
        child: Text('Quarterly history not loaded yet for these stocks.'),
      );
    }
    return SizedBox(
      height: 190,
      child: LineChart(
        LineChartData(
          lineBarsData: lines,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, meta) => Text(
                  v.toStringAsFixed(0),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                reservedSize: 22,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= labels.length || v != i.toDouble()) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    labels[i].replaceFirst('FY', "'"),
                    style: const TextStyle(fontSize: 10),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => const Color(0xEE1F2937),
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    indexed
                        ? s.y.toStringAsFixed(0)
                        : '${s.y.toStringAsFixed(1)}%',
                    TextStyle(
                      color: Color.lerp(s.bar.color, Colors.white, 0.45),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
