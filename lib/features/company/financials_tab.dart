import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import 'section.dart';

/// Balance sheet and cash flow, from half-year and full-year filings.
class FinancialsTab extends StatelessWidget {
  const FinancialsTab(this.c, {super.key});
  final Company c;

  @override
  Widget build(BuildContext context) {
    final withBs = c.quarters.where((q) => q.bs.isNotEmpty).take(5).toList();
    final withCf = c.quarters.where((q) => q.cf.isNotEmpty).take(5).toList();
    if (withBs.isEmpty && withCf.isEmpty) {
      return const EmptyState(
        icon: Icons.account_balance_outlined,
        message:
            'Balance sheet and cash flow are filed with half-year and full-year '
            'results. They appear once those filings are loaded.',
      );
    }
    final bank = withBs.isNotEmpty && withBs.first.bs.containsKey('deposits');
    final bsRows = bank
        ? const [
            ('Deposits', 'deposits', true),
            ('Advances (loans)', 'advances', true),
            ('Investments', 'investments', false),
            ('Borrowings', 'borrowings', false),
            ('Fixed assets', 'fixedAssets', false),
            ('Shareholders\' equity', 'equity', true),
            ('Total assets', 'totalAssets', true),
          ]
        : const [
            ('Fixed assets', 'fixedAssets', false),
            ('Capital work in progress', 'cwip', false),
            ('Goodwill', 'goodwill', false),
            ('Investments', 'investments', false),
            ('Inventories', 'inventories', false),
            ('Receivables', 'receivables', false),
            ('Cash & bank', 'cash', true),
            ('Total assets', 'totalAssets', true),
            ('Shareholders\' equity', 'equity', true),
            ('Minority interest', 'minority', false),
            ('Long-term borrowings', 'borrowingsLong', false),
            ('Short-term borrowings', 'borrowingsShort', false),
            ('Trade payables', 'payables', false),
          ];
    const cfRows = [
      ('Operating cash flow', 'cfo', true),
      ('Investing cash flow', 'cfi', false),
      ('Financing cash flow', 'cff', false),
      ('Capex', 'capex', false),
      ('Free cash flow', 'fcf', true),
      ('Dividends paid', 'dividends', false),
    ];

    String head(QuarterResult q, {bool cf = false}) {
      final m = cf ? (q.cf['months']?.round() ?? 0) : 0;
      final lbl = HoldingPoint(date: q.endDate).label;
      return cf ? '$lbl (${m}M)' : lbl;
    }

    final latestBs = withBs.isEmpty ? null : withBs.first;
    final debt = latestBs == null
        ? null
        : (latestBs.bs['borrowingsLong'] ?? 0) +
              (latestBs.bs['borrowingsShort'] ?? 0);
    final latestCf = withCf.isEmpty ? null : withCf.first;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (latestBs != null && !bank)
          Section(
            title: 'Health check',
            trailing: Text(
              head(latestBs),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Tile(
                  'Net cash',
                  crore((latestBs.bs['cash'] ?? 0) - (debt ?? 0)),
                  good: (latestBs.bs['cash'] ?? 0) >= (debt ?? 0),
                ),
                _Tile(
                  'Debt / equity',
                  debt != null && (latestBs.bs['equity'] ?? 0) > 0
                      ? (debt / latestBs.bs['equity']!).toStringAsFixed(2)
                      : '—',
                  good:
                      debt != null &&
                      (latestBs.bs['equity'] ?? 1) > 0 &&
                      debt / latestBs.bs['equity']! < 0.5,
                ),
                if (latestBs.bs['currentAssets'] != null &&
                    (latestBs.bs['currentLiabilities'] ?? 0) > 0)
                  _Tile(
                    'Current ratio',
                    (latestBs.bs['currentAssets']! /
                            latestBs.bs['currentLiabilities']!)
                        .toStringAsFixed(2),
                    good:
                        latestBs.bs['currentAssets']! /
                            latestBs.bs['currentLiabilities']! >=
                        1.2,
                  ),
                if (latestCf != null && latestCf.cf['cfo'] != null)
                  _Tile(
                    'Cash conversion',
                    _cashConversion(c, latestCf) ?? '—',
                    good: (_cashConversionValue(c, latestCf) ?? 0) >= 80,
                  ),
              ],
            ),
          ),
        if (withBs.isNotEmpty)
          Section(
            title: 'Balance sheet',
            trailing: Text(
              '₹ Cr',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            child: _Grid(
              columns: [for (final q in withBs) head(q)],
              rows: [
                for (final (label, key, bold) in bsRows)
                  if (withBs.any((q) => q.bs[key] != null))
                    (label, [for (final q in withBs) q.bs[key]], bold),
              ],
            ),
          ),
        if (withCf.isNotEmpty)
          Section(
            title: 'Cash flow',
            trailing: Text(
              '₹ Cr · year to date',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            child: _Grid(
              columns: [for (final q in withCf) head(q, cf: true)],
              rows: [
                for (final (label, key, bold) in cfRows)
                  if (withCf.any((q) => q.cf[key] != null))
                    (label, [for (final q in withCf) q.cf[key]], bold),
              ],
              colorSign: true,
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(
            'Indian companies file the balance sheet and cash flow every six months. '
            'Cash flow is cumulative from April (6M = Apr–Sep, 12M = full year).',
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  static double? _cashConversionValue(Company c, QuarterResult cfQ) {
    // Operating cash flow ÷ net profit over the same months.
    final months = cfQ.cf['months']?.round() ?? 0;
    final n = (months / 3).round();
    final idx = c.quarters.indexOf(cfQ);
    if (idx < 0 || n == 0 || idx + n > c.quarters.length) return null;
    final pat = c.quarters
        .skip(idx)
        .take(n)
        .fold<double>(0, (a, q) => a + (q.pat ?? 0));
    if (pat <= 0) return null;
    return cfQ.cf['cfo']! / pat * 100;
  }

  static String? _cashConversion(Company c, QuarterResult q) {
    final v = _cashConversionValue(c, q);
    return v == null ? null : '${v.toStringAsFixed(0)}%';
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {required this.good});
  final String label;
  final String value;
  final bool good;

  @override
  Widget build(BuildContext context) => Container(
    width: 150,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: (good ? gainColor : lossColor).withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: good ? gainColor : lossColor,
          ),
        ),
      ],
    ),
  );
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.columns,
    required this.rows,
    this.colorSign = false,
  });
  final List<String> columns;
  final List<(String, List<double?>, bool)> rows;
  final bool colorSign;

  @override
  Widget build(BuildContext context) {
    final head = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700);
    String n(double? v) =>
        v == null ? '—' : crore(v).replaceAll('₹', '').replaceAll(' Cr', '');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        horizontalMargin: 0,
        headingRowHeight: 34,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 34,
        columns: [
          DataColumn(label: Text('', style: head)),
          for (final c in columns)
            DataColumn(label: Text(c, style: head), numeric: true),
        ],
        rows: [
          for (final (label, vals, bold) in rows)
            DataRow(
              cells: [
                DataCell(
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
                for (final v in vals)
                  DataCell(
                    Text(
                      n(v),
                      style: TextStyle(
                        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                        color: colorSign && v != null && v < 0
                            ? lossColor
                            : null,
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
