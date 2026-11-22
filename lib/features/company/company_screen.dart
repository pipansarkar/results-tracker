import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import 'charts.dart';
import 'news_tab.dart';

class CompanyScreen extends ConsumerWidget {
  const CompanyScreen({super.key, required this.symbol});
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = ref.watch(companyProvider(symbol));
    final lite = ref
        .watch(companiesProvider)
        .value
        ?.where((c) => c.symbol == symbol)
        .firstOrNull;
    final name = company.value?.name ?? lite?.name ?? symbol;
    final sector = company.value?.sector ?? lite?.sector ?? '';

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, overflow: TextOverflow.ellipsis),
              Text(
                [symbol, if (sector.isNotEmpty) sector].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [WatchButton(symbol)],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Results'),
              Tab(text: 'Concalls'),
              Tab(text: 'Guidance'),
              Tab(text: 'News'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            company.when(
              loading: () => loading,
              error: asyncError,
              data: (c) => c == null || c.quarters.isEmpty
                  ? const EmptyState(
                      icon: Icons.hourglass_top,
                      message:
                          'Results for this company are still loading.\n'
                          'History for all NSE stocks fills in automatically. '
                          'Star it to get an alert when results are out.',
                    )
                  : _ResultsTab(c),
            ),
            _ConcallsTab(symbol),
            company.when(
              loading: () => loading,
              error: asyncError,
              data: (c) => c == null
                  ? const EmptyState(
                      icon: Icons.flag_outlined,
                      message:
                          'Guidance appears after the first concall summary.',
                    )
                  : _GuidanceTab(c),
            ),
            NewsTab(symbol: symbol, name: name),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ helpers

/// Rounded section card with a title row.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}

/// Change in percentage points, e.g. "+120 bps".
String _bps(double? now, double? before) {
  if (now == null || before == null) return '—';
  final d = ((now - before) * 100).round();
  return '${d > 0 ? '+' : ''}$d bps';
}

Color _signColor(double? v) =>
    v == null ? Colors.grey : (v >= 0 ? gainColor : lossColor);

// ------------------------------------------------------------------ results

enum _Metric { revenue, ebitda, profit, eps }

class _ResultsTab extends StatefulWidget {
  const _ResultsTab(this.c);
  final Company c;

  @override
  State<_ResultsTab> createState() => _ResultsTabState();
}

class _ResultsTabState extends State<_ResultsTab> {
  int _sel = 0; // index into quarters (0 = latest)
  _Metric _metric = _Metric.revenue;

  QuarterResult? _at(int i) {
    final qs = widget.c.quarters;
    return i >= 0 && i < qs.length ? qs[i] : null;
  }

  @override
  Widget build(BuildContext context) {
    final qs = widget.c.quarters;
    final q = qs[_sel];
    final prev = _at(_sel + 1);
    final ago = _at(_sel + 4);
    final last8 = qs.take(8).toList().reversed.toList();
    final selInChart = last8.indexOf(q);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SampleDataBanner(),
        // Quarter selector
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (var i = 0; i < qs.length && i < 8; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(qs[i].period),
                    selected: _sel == i,
                    onSelected: (_) => setState(() => _sel = i),
                  ),
                ),
            ],
          ),
        ),
        _Glance(q: q, prev: prev, ago: ago),
        _Section(
          title: 'Trend',
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<_Metric>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: _Metric.revenue,
                      label: Text('Revenue'),
                    ),
                    ButtonSegment(value: _Metric.ebitda, label: Text('EBITDA')),
                    ButtonSegment(value: _Metric.profit, label: Text('Profit')),
                    ButtonSegment(value: _Metric.eps, label: Text('EPS')),
                  ],
                  selected: {_metric},
                  onSelectionChanged: (v) => setState(() => _metric = v.first),
                ),
              ),
              QuarterBarChart(
                labels: last8.map((e) => e.period).toList(),
                values: last8
                    .map(
                      (e) =>
                          switch (_metric) {
                            _Metric.revenue => e.revenue,
                            _Metric.ebitda => e.ebitda,
                            _Metric.profit => e.pat,
                            _Metric.eps => e.eps,
                          } ??
                          0,
                    )
                    .toList(),
                color: _metric == _Metric.profit ? gainColor : null,
                highlight: selInChart >= 0 ? selInChart : null,
                unit: _metric == _Metric.eps ? '₹/share' : '₹ Cr',
              ),
            ],
          ),
        ),
        _Section(
          title: 'Margins',
          child: MarginLineChart(
            labels: last8.map((e) => e.period).toList(),
            ebitda: last8.map((e) => e.ebitdaMargin ?? 0).toList(),
            pat: last8.map((e) => e.patMargin ?? 0).toList(),
          ),
        ),
        _Section(
          title: 'Profit & loss',
          trailing: Text(
            '₹ Cr · ${q.consolidated ? 'Consolidated' : 'Standalone'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          child: _PnlTable(q: q, prev: prev, ago: ago),
        ),
        if (_costRows(q).isNotEmpty)
          _Section(
            title: 'Where each ₹100 of revenue went',
            child: _CostBreakdown(q),
          ),
        if (q.segments.isNotEmpty)
          _Section(
            title: 'Revenue by segment',
            trailing: Text(
              q.period,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            child: _Segments(q, ago),
          ),
        _Section(title: 'Quarterly history', child: _QuarterTable(qs)),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(disclaimerText, style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// Hero card: the selected quarter at a glance.
class _Glance extends StatelessWidget {
  const _Glance({required this.q, this.prev, this.ago});
  final QuarterResult q;
  final QuarterResult? prev;
  final QuarterResult? ago;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${q.period} at a glance',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'Quarter ended ${dayFormat.format(q.endDate)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, box) {
                final w = (box.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final k in [
                      _KpiData(
                        'Revenue',
                        crore(q.revenue),
                        q.revenue,
                        prev?.revenue,
                        ago?.revenue,
                      ),
                      _KpiData(
                        'EBITDA',
                        crore(q.ebitda),
                        q.ebitda,
                        prev?.ebitda,
                        ago?.ebitda,
                      ),
                      _KpiData(
                        'Net profit',
                        crore(q.pat),
                        q.pat,
                        prev?.pat,
                        ago?.pat,
                      ),
                      _KpiData(
                        'EPS',
                        '₹${num2(q.eps)}',
                        q.eps,
                        prev?.eps,
                        ago?.eps,
                      ),
                    ])
                      SizedBox(width: w, child: _Kpi(k)),
                    SizedBox(
                      width: w,
                      child: _MarginKpi(
                        'EBITDA margin',
                        q.ebitdaMargin,
                        ago?.ebitdaMargin,
                      ),
                    ),
                    SizedBox(
                      width: w,
                      child: _MarginKpi(
                        'Net margin',
                        q.patMargin,
                        ago?.patMargin,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _KpiData {
  const _KpiData(this.label, this.value, this.now, this.qBefore, this.yBefore);
  final String label;
  final String value;
  final double? now;
  final double? qBefore;
  final double? yBefore;
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.k);
  final _KpiData k;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k.label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 2),
        FittedBox(
          child: Text(
            k.value,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            GrowthChip(pctChange(k.now, k.yBefore), label: 'YoY'),
            GrowthChip(pctChange(k.now, k.qBefore), label: 'QoQ'),
          ],
        ),
      ],
    ),
  );
}

class _MarginKpi extends StatelessWidget {
  const _MarginKpi(this.label, this.now, this.yearAgo);
  final String label;
  final double? now;
  final double? yearAgo;

  @override
  Widget build(BuildContext context) {
    final d = (now != null && yearAgo != null) ? now! - yearAgo! : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(
            pct(now, signed: false),
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '${_bps(now, yearAgo)} YoY',
            style: TextStyle(
              color: _signColor(d),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full P&L statement: this quarter vs previous quarter and year-ago quarter.
class _PnlTable extends StatelessWidget {
  const _PnlTable({required this.q, this.prev, this.ago});
  final QuarterResult q;
  final QuarterResult? prev;
  final QuarterResult? ago;

  @override
  Widget build(BuildContext context) {
    // (label, getter, isBold, isPercent)
    final rows = <(String, double? Function(QuarterResult), bool, bool)>[
      ('Revenue from operations', (r) => r.revenue, true, false),
      ('Other income', (r) => r.otherIncome, false, false),
      ('Total income', (r) => r.totalIncome, false, false),
      ('Raw material cost', (r) => r.materialCost, false, false),
      ('Employee cost', (r) => r.employeeCost, false, false),
      ('Other expenses', (r) => r.otherExpenses, false, false),
      ('EBITDA', (r) => r.ebitda, true, false),
      ('EBITDA margin', (r) => r.ebitdaMargin, false, true),
      ('Depreciation', (r) => r.depreciation, false, false),
      ('Finance cost', (r) => r.financeCost, false, false),
      ('Exceptional items', (r) => r.exceptional, false, false),
      ('Profit before tax', (r) => r.pbt, true, false),
      ('Tax', (r) => r.tax, false, false),
      ('Effective tax rate', (r) => r.taxRate, false, true),
      ('Net profit', (r) => r.netProfit, false, false),
      ('Profit to shareholders', (r) => r.pat, true, false),
      ('Net margin', (r) => r.patMargin, false, true),
      ('EPS basic (₹)', (r) => r.eps, true, false),
      ('EPS diluted (₹)', (r) => r.dilutedEps, false, false),
    ];
    // Hide lines the company doesn't report, or reports as zero.
    final visible = rows.where((r) {
      final v = r.$2(q);
      return v != null && v != 0;
    }).toList();

    final head = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700);
    String fmt(double? v, bool isPct, String label) {
      if (v == null) return '—';
      if (isPct) return pct(v, signed: false);
      if (label.startsWith('EPS')) return v.toStringAsFixed(2);
      return crore(v).replaceAll('₹', '').replaceAll(' Cr', '');
    }

    final p = prev, a = ago;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 16,
        horizontalMargin: 0,
        headingRowHeight: 34,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 34,
        columns: [
          DataColumn(label: Text('', style: head)),
          DataColumn(label: Text(q.period, style: head), numeric: true),
          DataColumn(
            label: Text(p?.period ?? 'Prev', style: head),
            numeric: true,
          ),
          DataColumn(label: Text('QoQ', style: head), numeric: true),
          DataColumn(
            label: Text(a?.period ?? 'Yr ago', style: head),
            numeric: true,
          ),
          DataColumn(label: Text('YoY', style: head), numeric: true),
        ],
        rows: [
          for (final r in visible)
            DataRow(
              cells: [
                DataCell(
                  Text(
                    r.$1,
                    style: TextStyle(
                      fontWeight: r.$3 ? FontWeight.w700 : FontWeight.w400,
                      fontSize: 13,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    fmt(r.$2(q), r.$4, r.$1),
                    style: TextStyle(
                      fontWeight: r.$3 ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                DataCell(Text(p == null ? '—' : fmt(r.$2(p), r.$4, r.$1))),
                DataCell(_Delta(r.$2(q), p == null ? null : r.$2(p), r.$4)),
                DataCell(Text(a == null ? '—' : fmt(r.$2(a), r.$4, r.$1))),
                DataCell(_Delta(r.$2(q), a == null ? null : r.$2(a), r.$4)),
              ],
            ),
        ],
      ),
    );
  }
}

class _Delta extends StatelessWidget {
  const _Delta(this.now, this.before, this.isPct);
  final double? now;
  final double? before;
  final bool isPct;

  @override
  Widget build(BuildContext context) {
    if (isPct) {
      final n = now, b = before;
      final d = n != null && b != null ? n - b : null;
      return Text(
        _bps(n, b),
        style: TextStyle(color: _signColor(d), fontSize: 12),
      );
    }
    final p = pctChange(now, before);
    return Text(
      pct(p),
      style: TextStyle(
        color: _signColor(p),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

List<(String, double, Color)> _costRows(QuarterResult q) {
  final rev = q.revenue;
  if (rev == null || rev <= 0) return [];
  final rows = <(String, double?, Color)>[
    ('Raw materials', q.materialCost, const Color(0xFF6366F1)),
    ('Employees', q.employeeCost, const Color(0xFF0EA5E9)),
    ('Other expenses', q.otherExpenses, const Color(0xFFF59E0B)),
    ('Depreciation', q.depreciation, const Color(0xFF8B5CF6)),
    ('Interest', q.financeCost, const Color(0xFFEF4444)),
    ('Tax', q.tax, const Color(0xFF64748B)),
    ('Net profit', q.pat, gainColor),
  ];
  final out = <(String, double, Color)>[];
  for (final r in rows) {
    final v = r.$2;
    if (v != null && v > 0) out.add((r.$1, v / rev * 100, r.$3));
  }
  // Without a cost split (e.g. banks) this view isn't meaningful.
  return out.length >= 4 ? out : [];
}

class _CostBreakdown extends StatelessWidget {
  const _CostBreakdown(this.q);
  final QuarterResult q;

  @override
  Widget build(BuildContext context) {
    final rows = _costRows(q);
    final maxV = rows.map((r) => r.$2).fold<double>(1, (a, b) => b > a ? b : a);
    return Column(
      children: [
        // One stacked bar for the whole picture...
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 14,
            child: Row(
              children: [
                for (final r in rows)
                  Expanded(
                    flex: (r.$2 * 10).round().clamp(1, 100000),
                    child: Container(color: r.$3),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // ...and one row per item.
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: r.$3,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 104,
                  child: Text(r.$1, style: const TextStyle(fontSize: 13)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: r.$2 / maxV,
                      minHeight: 8,
                      color: r.$3,
                      backgroundColor: r.$3.withValues(alpha: 0.12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 46,
                  child: Text(
                    '₹${r.$2.toStringAsFixed(1)}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
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

class _Segments extends StatelessWidget {
  const _Segments(this.q, this.ago);
  final QuarterResult q;
  final QuarterResult? ago;

  @override
  Widget build(BuildContext context) {
    final total = q.segments.fold<double>(0, (a, s) => a + s.revenue);
    final agoBy = {
      for (final s in ago?.segments ?? const <Segment>[]) s.name: s.revenue,
    };
    final color = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in q.segments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      crore(s.revenue),
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    GrowthChip(
                      pctChange(s.revenue, agoBy[s.name]),
                      label: 'YoY',
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: total > 0 ? s.revenue / total : 0,
                          minHeight: 8,
                          color: color,
                          backgroundColor: color.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      child: Text(
                        total > 0
                            ? '${(s.revenue / total * 100).toStringAsFixed(0)}%'
                            : '',
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'Segment figures are before inter-segment eliminations.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _QuarterTable extends StatelessWidget {
  const _QuarterTable(this.quarters);
  final List<QuarterResult> quarters;

  @override
  Widget build(BuildContext context) {
    final head = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700);
    String n(double? v) => crore(v).replaceAll('₹', '').replaceAll(' Cr', '');
    QuarterResult? yearAgo(int i) =>
        i + 4 < quarters.length ? quarters[i + 4] : null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        horizontalMargin: 0,
        headingRowHeight: 34,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 34,
        columns: [
          DataColumn(label: Text('Quarter', style: head)),
          DataColumn(label: Text('Revenue', style: head), numeric: true),
          DataColumn(label: Text('YoY', style: head), numeric: true),
          DataColumn(label: Text('EBITDA', style: head), numeric: true),
          DataColumn(label: Text('Margin', style: head), numeric: true),
          DataColumn(label: Text('Profit', style: head), numeric: true),
          DataColumn(label: Text('YoY', style: head), numeric: true),
          DataColumn(label: Text('EPS', style: head), numeric: true),
        ],
        rows: [
          for (var i = 0; i < quarters.length; i++)
            DataRow(
              cells: [
                DataCell(
                  Text(
                    quarters[i].period,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                DataCell(Text(n(quarters[i].revenue))),
                DataCell(
                  _Delta(quarters[i].revenue, yearAgo(i)?.revenue, false),
                ),
                DataCell(Text(n(quarters[i].ebitda))),
                DataCell(Text(pct(quarters[i].ebitdaMargin, signed: false))),
                DataCell(Text(n(quarters[i].pat))),
                DataCell(_Delta(quarters[i].pat, yearAgo(i)?.pat, false)),
                DataCell(Text(num2(quarters[i].eps))),
              ],
            ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- concalls

class _ConcallsTab extends ConsumerWidget {
  const _ConcallsTab(this.symbol);
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(concallsProvider(symbol))
        .when(
          loading: () => loading,
          error: asyncError,
          data: (calls) => calls.isEmpty
              ? const EmptyState(
                  icon: Icons.record_voice_over_outlined,
                  message:
                      'No concall summaries yet.\nSummaries appear a few hours '
                      'after the company files its call transcript.',
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [for (final c in calls) _ConcallCard(symbol, c)],
                ),
        );
  }
}

class _ConcallCard extends StatelessWidget {
  const _ConcallCard(this.symbol, this.c);
  final String symbol;
  final Concall c;

  @override
  Widget build(BuildContext context) {
    final en = c.forLang('en');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push(
          '/company/${Uri.encodeComponent(symbol)}/concall/${c.period}',
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _ToneDot(c.tone),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${c.period} earnings call',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (c.date != null)
                    Text(
                      dayFormat.format(c.date!),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 8),
              for (final h in en.highlights.take(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '•  $h',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  Chip(
                    label: Text('Tone: ${c.tone}'),
                    visualDensity: VisualDensity.compact,
                  ),
                  if (en.redFlags.isNotEmpty)
                    Chip(
                      avatar: const Icon(
                        Icons.warning_amber,
                        size: 16,
                        color: lossColor,
                      ),
                      label: Text('${en.redFlags.length} red flags'),
                      visualDensity: VisualDensity.compact,
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

class _ToneDot extends StatelessWidget {
  const _ToneDot(this.tone);
  final String tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      'positive' => gainColor,
      'cautious' => lossColor,
      _ => Colors.amber.shade700,
    };
    return CircleAvatar(radius: 6, backgroundColor: color);
  }
}

// ----------------------------------------------------------------- guidance

class _GuidanceTab extends ConsumerWidget {
  const _GuidanceTab(this.c);
  final Company c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cred = c.credibility;
    final scheme = Theme.of(context).colorScheme;
    return ref
        .watch(guidanceProvider(c.symbol))
        .when(
          loading: () => loading,
          error: asyncError,
          data: (items) => ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 72,
                        height: 72,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox.expand(
                              child: CircularProgressIndicator(
                                value: cred.score / 100,
                                strokeWidth: 7,
                                backgroundColor: scheme.surfaceContainerHighest,
                                color: cred.score >= 70
                                    ? gainColor
                                    : (cred.score >= 40
                                          ? Colors.amber.shade700
                                          : lossColor),
                              ),
                            ),
                            Text(
                              '${cred.score}',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Management credibility',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${cred.met} promises met · ${cred.missed} missed · '
                              '${cred.pending} pending',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Guidance given in past concalls compared with reported results.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No guidance tracked yet. It is extracted from concall transcripts.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final g in items) _GuidanceTile(g),
            ],
          ),
        );
  }
}

class _GuidanceTile extends StatelessWidget {
  const _GuidanceTile(this.g);
  final GuidanceItem g;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (g.status) {
      GuidanceStatus.met => (Icons.check_circle, gainColor, 'Met'),
      GuidanceStatus.missed => (Icons.cancel, lossColor, 'Missed'),
      GuidanceStatus.pending => (Icons.schedule, Colors.grey, 'Pending'),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(g.statement),
      subtitle: Text(
        'Said in ${g.madeIn} · for ${g.targetPeriod}'
        '${g.actual == null ? '' : ' · actual ${g.actual}'}',
      ),
      trailing: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
