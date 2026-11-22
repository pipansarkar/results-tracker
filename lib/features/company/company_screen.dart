import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import 'charts.dart';
import 'events_tab.dart';
import 'financials_tab.dart';
import 'ownership_tab.dart';
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
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, overflow: TextOverflow.ellipsis),
              Text(
                [
                  symbol,
                  if (lite?.capLabel != null) lite!.capLabel!,
                  if (sector.isNotEmpty) sector,
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Compare with other stocks',
              icon: const Icon(Icons.compare_arrows),
              onPressed: () =>
                  context.push('/compare?s=${Uri.encodeComponent(symbol)}'),
            ),
            WatchButton(symbol),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Results'),
              Tab(text: 'Financials'),
              Tab(text: 'Ownership'),
              Tab(text: 'Events'),
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
            company.when(
              loading: () => loading,
              error: asyncError,
              data: (c) => c == null
                  ? EmptyState(
                      icon: Icons.hourglass_top,
                      message: 'Financials are still loading.',
                    )
                  : FinancialsTab(c),
            ),
            company.when(
              loading: () => loading,
              error: asyncError,
              data: (c) => c == null
                  ? EmptyState(
                      icon: Icons.hourglass_top,
                      message: 'Ownership data is still loading.',
                    )
                  : OwnershipTab(c),
            ),
            company.when(
              loading: () => loading,
              error: asyncError,
              data: (c) => c == null
                  ? const EmptyState(
                      icon: Icons.hourglass_top,
                      message: 'Events are still loading.',
                    )
                  : EventsTab(c),
            ),
            _ConcallsTab(symbol),
            company.when(
              loading: () => loading,
              error: asyncError,
              data: (c) => c == null
                  ? EmptyState(
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
              if (trailing != null) Flexible(child: trailing!),
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
        _KeyRatios(widget.c.symbol),
        _Glance(q: q, prev: prev, ago: ago, story: quarterStory(qs, _sel)),
        _Section(
          title: 'Trend',
          child: Column(
            children: [
              // Chips wrap on narrow phones instead of overflowing.
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final (m, label) in const [
                      (_Metric.revenue, 'Revenue'),
                      (_Metric.ebitda, 'EBITDA'),
                      (_Metric.profit, 'Profit'),
                      (_Metric.eps, 'EPS'),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _metric == m,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _metric = m),
                      ),
                  ],
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
        _Peers(widget.c),
        _Section(title: 'Quarterly history', child: _QuarterTable(qs)),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(disclaimerText, style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// Valuation & quality ratios (price-based, from the screener data).
class _KeyRatios extends ConsumerWidget {
  const _KeyRatios(this.symbol);
  final String symbol;

  static const _keys = [
    'p',
    'mc',
    'pe',
    'peg',
    'pb',
    'ev',
    'roe',
    'roce',
    'de',
    'ebm',
    'npm',
    'eps',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(metricsProvider(symbol));
    if (m == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final defs = _keys.map(metricDef).where((d) => d.get(m) != null).toList();
    return _Section(
      title: 'Key ratios',
      trailing: Text(
        m.asOf == null
            ? 'TTM · at last close'
            : 'TTM · as of ${dayFormat.format(DateTime.parse(m.asOf!))} close',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = (box.maxWidth - 16) / 3;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final d in defs)
                Tooltip(
                  message: d.help,
                  triggerMode: TooltipTriggerMode.tap,
                  child: Container(
                    width: w,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.short,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          child: Text(
                            metricValue(d.get(m), d.unit),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
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

/// Same-sector companies by market cap, with key ratios.
class _Peers extends ConsumerWidget {
  const _Peers(this.c);
  final Company c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (c.sector.isEmpty) return const SizedBox.shrink();
    final companies = ref.watch(companiesProvider).value ?? const [];
    final metrics = {
      for (final m
          in ref.watch(screenerProvider).value ?? const <StockMetrics>[])
        m.symbol: m,
    };
    final names = {for (final x in companies) x.symbol: x.name};
    final peers =
        companies
            .where((x) => x.sector == c.sector && metrics[x.symbol] != null)
            .map((x) => metrics[x.symbol]!)
            .toList()
          ..sort((a, b) => (b.marketCap ?? 0).compareTo(a.marketCap ?? 0));
    var top = peers.take(6).toList();
    if (!top.any((m) => m.symbol == c.symbol) && metrics[c.symbol] != null) {
      top = [...top.take(5), metrics[c.symbol]!];
    }
    if (top.length < 2) return const SizedBox.shrink();
    const keys = ['mc', 'pe', 'roe', 'rg', 'pg', 'npm'];
    final head = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700);
    return _Section(
      title: 'Peers · ${c.sector}',
      trailing: TextButton(
        onPressed: () => context.push(
          '/compare?s=${top.take(4).map((m) => Uri.encodeComponent(m.symbol)).join(',')}',
        ),
        child: Text('Compare'),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 14,
          horizontalMargin: 0,
          headingRowHeight: 32,
          dataRowMinHeight: 32,
          dataRowMaxHeight: 36,
          showCheckboxColumn: false,
          columns: [
            DataColumn(label: Text('Company', style: head)),
            for (final k in keys)
              DataColumn(
                label: Text(metricDef(k).short, style: head),
                numeric: true,
              ),
          ],
          rows: [
            for (final m in top)
              DataRow(
                color: WidgetStatePropertyAll(
                  m.symbol == c.symbol
                      ? Theme.of(
                          context,
                        ).colorScheme.primaryContainer.withValues(alpha: 0.4)
                      : null,
                ),
                onSelectChanged: m.symbol == c.symbol
                    ? null
                    : (_) => context.push(
                        '/company/${Uri.encodeComponent(m.symbol)}',
                      ),
                cells: [
                  DataCell(
                    SizedBox(
                      width: 120,
                      child: Text(
                        names[m.symbol] ?? m.symbol,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  for (final k in keys)
                    DataCell(
                      Text(
                        k == 'rg' || k == 'pg'
                            ? pct(metricDef(k).get(m))
                            : metricValue(
                                metricDef(k).get(m),
                                metricDef(k).unit,
                              ),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Hero card: the selected quarter at a glance.
class _Glance extends StatelessWidget {
  const _Glance({required this.q, this.prev, this.ago, this.story = const []});
  final QuarterResult q;
  final QuarterResult? prev;
  final QuarterResult? ago;
  final List<String> story;

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
            if (story.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final b in story) StoryBadge(b)],
              ),
            ],
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
                    if (q.reaction != null)
                      SizedBox(width: box.maxWidth, child: _ReactionTile(q)),
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

class _ReactionTile extends StatelessWidget {
  const _ReactionTile(this.q);
  final QuarterResult q;

  @override
  Widget build(BuildContext context) {
    final r = q.reaction!;
    final color = r >= 0 ? gainColor : lossColor;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(r >= 0 ? Icons.trending_up : Icons.trending_down, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Share price reaction to these results',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Text(
            '${r > 0 ? '+' : ''}${r.toStringAsFixed(2)}%',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
        ],
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
          DataColumn(label: Text('Price move', style: head), numeric: true),
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
                DataCell(
                  Text(
                    quarters[i].reaction == null
                        ? '—'
                        : pct(quarters[i].reaction),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: quarters[i].reaction == null
                          ? null
                          : (quarters[i].reaction! >= 0
                                ? gainColor
                                : lossColor),
                    ),
                  ),
                ),
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
          '/company/${Uri.encodeComponent(symbol)}/concall/${c.id}',
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
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          c.period,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        CallTypeLabel(c),
                      ],
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
              _LatestGuidanceChanges(c.symbol),
              _Promises(c.symbol),
              if (items.isEmpty)
                Padding(
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

/// Guidance diff from the most recent concall vs the one before.
class _LatestGuidanceChanges extends ConsumerWidget {
  const _LatestGuidanceChanges(this.symbol);
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calls = ref.watch(concallsProvider(symbol)).value ?? const [];
    final latest = calls.where((c) => c.guidanceDiff.isNotEmpty).firstOrNull;
    if (latest == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Guidance changes · ${latest.period} vs ${latest.previousPeriod ?? 'previous call'}',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final g in latest.guidanceDiff) GuidanceChangeTile(g),
          ],
        ),
      ),
    );
  }
}

/// One raised / cut / reiterated / new / dropped guidance line.
class GuidanceChangeTile extends StatelessWidget {
  const GuidanceChangeTile(this.g, {super.key});
  final GuidanceChange g;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (g.direction) {
      'raised' => (Icons.arrow_upward, gainColor, 'Raised'),
      'cut' => (Icons.arrow_downward, lossColor, 'Cut'),
      'dropped' => (Icons.remove_circle_outline, lossColor, 'Dropped'),
      'new' => (Icons.fiber_new_outlined, Colors.blue, 'New'),
      _ => (Icons.check, Colors.grey, 'Reiterated'),
    };
    final from = g.before, to = g.now;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${g.label} · ${g.targetPeriod}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(switch (g.direction) {
                  'new' => 'New target: ${to ?? ''}',
                  'dropped' => 'Was ${from ?? ''}, no longer mentioned',
                  _ => '${from ?? '—'}  →  ${to ?? '—'}',
                }, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Commitments (capacity, plants, launches, capex…) across all calls, with
/// their latest status.
class _Promises extends ConsumerWidget {
  const _Promises(this.symbol);
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calls =
        (ref.watch(concallsProvider(symbol)).value ?? const <Concall>[])
            .where((c) => !c.isDocument)
            .toList()
          ..sort(
            (a, b) =>
                (a.date ?? DateTime(2000)).compareTo(b.date ?? DateTime(2000)),
          );
    // item (normalised) -> (first period, latest promise, latest period)
    final latest = <String, (String, Promise, String)>{};
    for (final c in calls) {
      for (final p in c.forLang('en').promises) {
        final k = p.item
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
            .trim();
        final first = latest[k]?.$1 ?? c.period;
        latest[k] = (first, p, c.period);
      }
    }
    if (latest.isEmpty) return const SizedBox.shrink();
    final order = {
      'delayed': 0,
      'dropped': 1,
      'on_track': 2,
      'new': 3,
      'completed': 4,
    };
    final items = latest.values.toList()
      ..sort(
        (a, b) => (order[a.$2.status] ?? 9).compareTo(order[b.$2.status] ?? 9),
      );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Promises tracker',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'Capacity, capex, launches and other commitments made on calls.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final (first, p, last) in items) _PromiseTile(p, first, last),
          ],
        ),
      ),
    );
  }
}

class _PromiseTile extends StatelessWidget {
  const _PromiseTile(this.p, this.first, this.last);
  final Promise p;
  final String first, last;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (p.status) {
      'completed' => (gainColor, 'Completed'),
      'on_track' => (Colors.blue, 'On track'),
      'delayed' => (Colors.amber.shade800, 'Delayed'),
      'dropped' => (lossColor, 'Dropped'),
      _ => (Colors.grey, 'New'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.item,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  [
                    if (p.target != null) 'Target ${p.target}',
                    first == last
                        ? 'said in $first'
                        : 'since $first, last update $last',
                    if ((p.note ?? '').isNotEmpty) p.note!,
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
