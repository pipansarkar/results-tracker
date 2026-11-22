import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../core/i18n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import 'section.dart';

const _cats = <(String, Color, double? Function(HoldingPoint))>[
  ('Promoters', Color(0xFF2563EB), _promoter),
  ('FII', Color(0xFFDB2777), _fii),
  ('DII', Color(0xFF059669), _dii),
  ('Retail', Color(0xFFF59E0B), _retail),
  ('Others', Color(0xFF94A3B8), _others),
];
double? _promoter(HoldingPoint h) => h.promoter;
double? _fii(HoldingPoint h) => h.fii;
double? _dii(HoldingPoint h) => h.dii;
double? _retail(HoldingPoint h) => h.retail;
double? _others(HoldingPoint h) => h.others;

/// Shareholding pattern, pledge, deals and red flags for one company.
class OwnershipTab extends ConsumerWidget {
  const OwnershipTab(this.c, {super.key});
  final Company c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(activityProvider(c.symbol));
    final h = c.holding;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (h.isEmpty)
          Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              tr('Shareholding pattern is still loading for this company.'),
              textAlign: TextAlign.center,
            ),
          )
        else ...[
          Section(
            title: tr('Who owns the company'),
            trailing: Text(
              h.first.label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            child: _Latest(h),
          ),
          if (h.length >= 2)
            Section(
              title: tr('Trend'),
              child: _Trend(h.take(6).toList().reversed.toList()),
            ),
          Section(title: tr('History (%)'), child: _Table(h.take(6).toList())),
        ],
        Section(
          title: tr('Deals, stake changes & red flags'),
          child: activity.when(
            loading: () =>
                const Padding(padding: EdgeInsets.all(16), child: loading),
            error: (e, _) => Text('Could not load: $e'),
            data: (items) => items.isEmpty
                ? Text(
                    tr(
                      'No bulk/block deals, stake changes or red flags recorded yet.',
                    ),
                  )
                : Column(
                    children: [for (final a in items.take(40)) ActivityTile(a)],
                  ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(
            'From NSE filings: shareholding patterns (quarterly), bulk & block deals, '
            'SAST disclosures (holders crossing 5% and every 2% after), and company '
            'announcements. FII = foreign institutions, DII = domestic institutions.',
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _Latest extends StatelessWidget {
  const _Latest(this.h);
  final List<HoldingPoint> h;

  @override
  Widget build(BuildContext context) {
    final now = h.first;
    final prev = h.length > 1 ? h[1] : null;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 16,
            child: Row(
              children: [
                for (final (_, color, get) in _cats)
                  if ((get(now) ?? 0) > 0)
                    Expanded(
                      flex: ((get(now) ?? 0) * 10).round().clamp(1, 1000),
                      child: Container(color: color),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        for (final (label, color, get) in _cats)
          if (get(now) != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(label)),
                  Text(
                    '${get(now)!.toStringAsFixed(2)}%',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 70,
                    child: _Change(prev == null ? null : get(prev), get(now)),
                  ),
                ],
              ),
            ),
        if (now.mf != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Within DII: mutual funds ${now.mf!.toStringAsFixed(2)}%'
              '${now.insurance != null ? ', insurance ${now.insurance!.toStringAsFixed(2)}%' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (now.pledge != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: (now.pledge! > 0 ? lossColor : gainColor).withValues(
                alpha: 0.08,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  now.pledge! > 0 ? Icons.lock_outline : Icons.lock_open,
                  color: now.pledge! > 0 ? lossColor : gainColor,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    now.pledge! > 0
                        ? 'Promoter pledge: ${now.pledge!.toStringAsFixed(2)}% of promoter shares'
                        : 'No promoter shares pledged',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Change extends StatelessWidget {
  const _Change(this.before, this.now);
  final double? before, now;

  @override
  Widget build(BuildContext context) {
    if (before == null || now == null) return const SizedBox.shrink();
    final d = now! - before!;
    if (d.abs() < 0.01) {
      return const Text(
        '—',
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 12),
      );
    }
    return Text(
      '${d > 0 ? '▲' : '▼'} ${d.abs().toStringAsFixed(2)}',
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 12,
        color: d > 0 ? gainColor : lossColor,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend(this.h);
  final List<HoldingPoint> h; // oldest first

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 170,
          child: LineChart(
            LineChartData(
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
                    reservedSize: 30,
                    getTitlesWidget: (v, m) => Text(
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
                    getTitlesWidget: (v, m) {
                      final i = v.toInt();
                      if (i < 0 || i >= h.length || v != i.toDouble())
                        return const SizedBox.shrink();
                      return Text(
                        h[i].label,
                        style: const TextStyle(fontSize: 10),
                      );
                    },
                  ),
                ),
              ),
              lineBarsData: [
                for (final (_, color, get) in _cats.take(4))
                  LineChartBarData(
                    spots: [
                      for (var i = 0; i < h.length; i++)
                        if (get(h[i]) != null) FlSpot(i.toDouble(), get(h[i])!),
                    ],
                    color: color,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: true),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          children: [
            for (final (label, color, _) in _cats.take(4))
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 10, height: 10, color: color),
                  const SizedBox(width: 4),
                  Text(label, style: const TextStyle(fontSize: 12)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _Table extends StatelessWidget {
  const _Table(this.h);
  final List<HoldingPoint> h; // newest first

  @override
  Widget build(BuildContext context) {
    final head = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700);
    final rows = <(String, double? Function(HoldingPoint))>[
      ..._cats.map((c) => (c.$1, c.$3)),
      ('Mutual funds', (x) => x.mf),
      ('Insurance', (x) => x.insurance),
      ('Pledge (of promoter)', (x) => x.pledge),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 16,
        horizontalMargin: 0,
        headingRowHeight: 32,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 32,
        columns: [
          DataColumn(label: Text('', style: head)),
          for (final p in h)
            DataColumn(label: Text(p.label, style: head), numeric: true),
        ],
        rows: [
          for (final (label, get) in rows)
            if (h.any((p) => get(p) != null))
              DataRow(
                cells: [
                  DataCell(Text(label, style: const TextStyle(fontSize: 13))),
                  for (final p in h)
                    DataCell(
                      Text(get(p) == null ? '—' : get(p)!.toStringAsFixed(2)),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}

/// One deal / stake change / ownership shift / red flag.
class ActivityTile extends StatelessWidget {
  const ActivityTile(this.a, {super.key, this.company});
  final ActivityItem a;
  final String? company;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, title) = switch (a.kind) {
      'flag' => (
        Icons.warning_amber_rounded,
        a.severity == 'high' ? lossColor : Colors.amber.shade800,
        a.text ?? 'Red flag',
      ),
      'holding' => (
        Icons.pie_chart_outline,
        scheme.primary,
        a.text ?? 'Shareholding change',
      ),
      _ => (
        a.side == 'buy' ? Icons.south_west : Icons.north_east,
        a.side == 'buy' ? gainColor : lossColor,
        '${a.promoter ? 'Promoter · ' : ''}${a.who ?? ''}',
      ),
    };
    final kind = switch (a.kind) {
      'bulk' => 'Bulk deal',
      'block' => 'Block deal',
      'sast' => 'Stake change (SAST)',
      'insider' => 'Insider trade',
      'holding' => 'Shareholding',
      'flag' => 'Red flag',
      _ => a.kind,
    };
    final parts = <String>[
      if (company != null) company!,
      kind,
      if (a.isDeal) a.side == 'buy' ? 'Bought' : 'Sold',
      if (a.valueCr != null) '₹${a.valueCr!.toStringAsFixed(1)} Cr',
      if (a.valueCr == null && a.qty != null)
        '${(a.qty! / 1e5).toStringAsFixed(2)} lakh shares',
      if (a.price != null) '@ ₹${a.price!.toStringAsFixed(2)}',
      if (a.holdingAfter != null) 'now ${a.holdingAfter!.toStringAsFixed(2)}%',
      if (a.intraday) 'intraday',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        [parts.join(' · '), if (a.detail != null) a.detail!].join('\n'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        dayFormat.format(a.date),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: a.url == null
          ? null
          : () => launchUrl(
              Uri.parse(a.url!),
              mode: LaunchMode.externalApplication,
            ),
    );
  }
}
