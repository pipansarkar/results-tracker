import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import 'charts.dart';

class CompanyScreen extends ConsumerWidget {
  const CompanyScreen({super.key, required this.symbol});
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final company = ref.watch(companyProvider(symbol));
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            company.value?.name ??
                ref
                    .watch(companiesProvider)
                    .value
                    ?.where((c) => c.symbol == symbol)
                    .firstOrNull
                    ?.name ??
                symbol,
          ),
          actions: [WatchButton(symbol)],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Results'),
              Tab(text: 'Concalls'),
              Tab(text: 'Guidance'),
            ],
          ),
        ),
        body: company.when(
          loading: () => loading,
          error: asyncError,
          data: (c) => c == null
              ? const EmptyState(
                  icon: Icons.inventory_2_outlined,
                  message:
                      'Results for this company are still loading.\n'
                      'History for all NSE stocks fills in automatically over '
                      'the first few days. Star it to get an alert when results are out.',
                )
              : TabBarView(
                  children: [
                    _ResultsTab(c),
                    _ConcallsTab(c.symbol),
                    _GuidanceTab(c),
                  ],
                ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ results

class _ResultsTab extends StatelessWidget {
  const _ResultsTab(this.c);
  final Company c;

  @override
  Widget build(BuildContext context) {
    final l = c.latest;
    if (l == null) {
      return const EmptyState(
        icon: Icons.bar_chart,
        message: 'No results filed yet.',
      );
    }
    final q = c.previousQuarter;
    final y = c.yearAgoQuarter;
    final last8 = c.quarters.take(8).toList().reversed.toList();

    return ListView(
      children: [
        const SampleDataBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '${c.symbol} · ${c.sector} · ${l.period} '
            '(${l.consolidated ? 'consolidated' : 'standalone'})',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.7,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              _Kpi(
                'Revenue',
                crore(l.revenue),
                pctChange(l.revenue, y?.revenue),
                pctChange(l.revenue, q?.revenue),
              ),
              _Kpi(
                'EBITDA',
                crore(l.ebitda),
                pctChange(l.ebitda, y?.ebitda),
                pctChange(l.ebitda, q?.ebitda),
              ),
              _Kpi(
                'Net profit',
                crore(l.pat),
                pctChange(l.pat, y?.pat),
                pctChange(l.pat, q?.pat),
              ),
              _Kpi(
                'EPS',
                '₹${num2(l.eps)}',
                pctChange(l.eps, y?.eps),
                pctChange(l.eps, q?.eps),
              ),
            ],
          ),
        ),
        SectionHeader('Revenue (₹ Cr)'),
        QuarterBarChart(
          labels: last8.map((e) => e.period).toList(),
          values: last8.map((e) => e.revenue ?? 0).toList(),
        ),
        SectionHeader('Net profit (₹ Cr)'),
        QuarterBarChart(
          labels: last8.map((e) => e.period).toList(),
          values: last8.map((e) => e.pat ?? 0).toList(),
          color: gainColor,
        ),
        SectionHeader('Margins (%)'),
        MarginLineChart(
          labels: last8.map((e) => e.period).toList(),
          ebitda: last8.map((e) => e.ebitdaMargin ?? 0).toList(),
          pat: last8.map((e) => e.patMargin ?? 0).toList(),
        ),
        const SectionHeader('Quarterly table'),
        _QuarterTable(c.quarters),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(disclaimerText, style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.yoy, this.qoq);
  final String label;
  final String value;
  final double? yoy;
  final double? qoq;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          FittedBox(
            child: Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              GrowthChip(yoy, label: 'YoY'),
              GrowthChip(qoq, label: 'QoQ'),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuarterTable extends StatelessWidget {
  const _QuarterTable(this.quarters);
  final List<QuarterResult> quarters;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 36,
        columns: const [
          DataColumn(label: Text('Quarter')),
          DataColumn(label: Text('Revenue'), numeric: true),
          DataColumn(label: Text('EBITDA'), numeric: true),
          DataColumn(label: Text('Margin'), numeric: true),
          DataColumn(label: Text('PAT'), numeric: true),
          DataColumn(label: Text('EPS'), numeric: true),
          DataColumn(label: Text('Rev YoY'), numeric: true),
        ],
        rows: [
          for (var i = 0; i < quarters.length; i++)
            DataRow(
              cells: [
                DataCell(Text(quarters[i].period)),
                DataCell(
                  Text(crore(quarters[i].revenue).replaceAll(' Cr', '')),
                ),
                DataCell(Text(crore(quarters[i].ebitda).replaceAll(' Cr', ''))),
                DataCell(Text(pct(quarters[i].ebitdaMargin, signed: false))),
                DataCell(Text(crore(quarters[i].pat).replaceAll(' Cr', ''))),
                DataCell(Text(num2(quarters[i].eps))),
                DataCell(
                  GrowthChip(
                    i + 4 < quarters.length
                        ? pctChange(
                            quarters[i].revenue,
                            quarters[i + 4].revenue,
                          )
                        : null,
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
                  message: 'No concall summaries yet.',
                )
              : ListView(
                  children: [
                    for (final c in calls)
                      Card(
                        child: ListTile(
                          leading: _ToneDot(c.tone),
                          title: Text('${c.period} earnings call'),
                          subtitle: Text(
                            [
                              if (c.date != null) dayFormat.format(c.date!),
                              'Tone: ${c.tone}',
                              if (c.forLang('en').redFlags.isNotEmpty)
                                '${c.forLang('en').redFlags.length} red flags',
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.push(
                            '/company/${Uri.encodeComponent(symbol)}/concall/${c.period}',
                          ),
                        ),
                      ),
                  ],
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
    return CircleAvatar(radius: 8, backgroundColor: color);
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
                              'Based on guidance given in past concalls compared with reported results.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              for (final g in items) _GuidanceTile(g),
              const SizedBox(height: 24),
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
