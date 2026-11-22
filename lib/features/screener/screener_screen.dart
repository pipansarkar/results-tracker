import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

typedef Range = (double?, double?);

/// One-tap screens. Each sets a group of min/max filters.
class _Preset {
  const _Preset(this.label, this.icon, this.filters, {this.sort = 'mc'});
  final String label;
  final IconData icon;
  final Map<String, Range> filters;
  final String sort;
}

const _presets = [
  _Preset('High quality', Icons.workspace_premium, {
    'roe': (20, null),
    'roce': (20, null),
    'de': (null, 0.5),
  }, sort: 'roe'),
  _Preset('Value', Icons.sell_outlined, {
    'pe': (0, 15),
    'roe': (12, null),
  }, sort: 'pe'),
  _Preset('Fast growth', Icons.trending_up, {
    'rg': (20, null),
    'pg': (20, null),
  }, sort: 'pg'),
  _Preset('PEG under 1', Icons.speed, {'peg': (0, 1)}, sort: 'peg'),
  _Preset('Debt-free', Icons.shield_outlined, {'de': (null, 0.05)}),
  _Preset('Large caps', Icons.account_balance, {'mc': (50000, null)}),
  _Preset('Profit jump', Icons.rocket_launch_outlined, {
    'pg': (50, null),
  }, sort: 'pg'),
  _Preset('High margins', Icons.percent, {'npm': (20, null)}, sort: 'npm'),
];

/// Metrics offered as filters in the sheet.
const _filterKeys = [
  'mc',
  'pe',
  'peg',
  'pb',
  'ev',
  'roe',
  'roce',
  'de',
  'rg',
  'pg',
  'rgt',
  'ebm',
  'npm',
];

/// Metrics shown as pills on each row (plus the sort metric).
const _rowKeys = ['mc', 'pe', 'roe', 'rg'];

class ScreenerScreen extends ConsumerStatefulWidget {
  const ScreenerScreen({super.key});

  @override
  ConsumerState<ScreenerScreen> createState() => _ScreenerScreenState();
}

class _ScreenerScreenState extends ConsumerState<ScreenerScreen> {
  String _q = '';
  String? _sector;
  bool _n500 = false;
  Map<String, Range> _filters = {};
  String? _preset;
  String _sort = 'mc';
  bool _desc = true;
  final Set<String> _picked = {};

  bool _pass(StockMetrics m, CompanyLite? c) {
    if (_n500 && !(c?.nifty500 ?? false)) return false;
    if (_sector != null && c?.sector != _sector) return false;
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      if (!m.symbol.toLowerCase().contains(q) &&
          !(c?.name.toLowerCase().contains(q) ?? false)) {
        return false;
      }
    }
    for (final f in _filters.entries) {
      final v = metricDef(f.key).get(m);
      if (v == null) return false;
      final (lo, hi) = f.value;
      if (lo != null && v < lo) return false;
      if (hi != null && v > hi) return false;
    }
    return true;
  }

  void _applyPreset(_Preset p) => setState(() {
    if (_preset == p.label) {
      _preset = null;
      _filters = {};
      _sort = 'mc';
      _desc = true;
    } else {
      _preset = p.label;
      _filters = Map.of(p.filters);
      _sort = p.sort;
      _desc = !['pe', 'peg', 'pb', 'ev', 'de'].contains(p.sort);
    }
  });

  @override
  Widget build(BuildContext context) {
    final screener = ref.watch(screenerProvider);
    final companies = ref.watch(companiesProvider).value ?? const [];
    final bySym = {for (final c in companies) c.symbol: c};
    final sortDef = metricDef(_sort);

    return Scaffold(
      appBar: AppBar(
        title: Text('Screener'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Sort by',
            icon: const Icon(Icons.sort),
            onSelected: (k) => setState(() {
              if (k == _sort) {
                _desc = !_desc;
              } else {
                _sort = k;
                _desc = metricDef(k).higherIsBetter;
              }
            }),
            itemBuilder: (_) => [
              for (final d in metricDefs)
                CheckedPopupMenuItem(
                  value: d.key,
                  checked: d.key == _sort,
                  child: Text(d.label),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Filters',
            icon: Badge(
              isLabelVisible: _filters.isNotEmpty || _sector != null || _n500,
              child: const Icon(Icons.tune),
            ),
            onPressed: () => _openFilters(companies),
          ),
        ],
      ),
      floatingActionButton: _picked.length >= 2
          ? FloatingActionButton.extended(
              onPressed: () => context.push(
                '/compare?s=${_picked.map(Uri.encodeComponent).join(',')}',
              ),
              icon: const Icon(Icons.compare_arrows),
              label: Text('Compare ${_picked.length}'),
            )
          : null,
      body: Column(
        children: [
          const SampleDataBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SearchBar(
              hintText: 'Filter by name or symbol',
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final p in _presets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      avatar: Icon(p.icon, size: 16),
                      label: Text(p.label),
                      selected: _preset == p.label,
                      onSelected: (_) => _applyPreset(p),
                    ),
                  ),
              ],
            ),
          ),
          if (_filters.isNotEmpty || _sector != null || _n500)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  if (_n500)
                    _ActiveChip(
                      'Nifty 500',
                      () => setState(() => _n500 = false),
                    ),
                  if (_sector != null)
                    _ActiveChip(_sector!, () => setState(() => _sector = null)),
                  for (final f in _filters.entries)
                    _ActiveChip(
                      _rangeLabel(metricDef(f.key), f.value),
                      () => setState(() {
                        _filters = Map.of(_filters)..remove(f.key);
                        _preset = null;
                      }),
                    ),
                ],
              ),
            ),
          Expanded(
            child: screener.when(
              loading: () => loading,
              error: asyncError,
              data: (all) {
                final rows = all
                    .where((m) => _pass(m, bySym[m.symbol]))
                    .toList();
                rows.sort((a, b) {
                  final va = sortDef.get(a), vb = sortDef.get(b);
                  if (va == null && vb == null) return 0;
                  if (va == null) return 1; // missing values last
                  if (vb == null) return -1;
                  return _desc ? vb.compareTo(va) : va.compareTo(vb);
                });
                if (all.isEmpty) {
                  return const EmptyState(
                    icon: Icons.hourglass_top,
                    message:
                        'Ratios are being calculated. They appear after the '
                        'next pipeline run.',
                  );
                }
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                      child: Row(
                        children: [
                          Text(
                            '${rows.length} stocks',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          Text(
                            'Sorted by ${sortDef.short} ${_desc ? '↓' : '↑'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (_picked.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Tick 2–4 stocks to compare (${_picked.length} picked)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    Expanded(
                      child: rows.isEmpty
                          ? EmptyState(
                              icon: Icons.filter_alt_off,
                              message: 'No stocks match these filters.',
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 88),
                              itemCount: rows.length.clamp(0, 300),
                              itemBuilder: (_, i) => _Row(
                                m: rows[i],
                                c: bySym[rows[i].symbol],
                                sortKey: _sort,
                                picked: _picked.contains(rows[i].symbol),
                                onPick: (v) => setState(() {
                                  if (v && _picked.length < 4) {
                                    _picked.add(rows[i].symbol);
                                  } else {
                                    _picked.remove(rows[i].symbol);
                                  }
                                }),
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _rangeLabel(MetricDef d, Range r) {
    final (lo, hi) = r;
    String f(double v) => metricValue(v, d.unit);
    if (lo != null && hi != null) return '${d.short} ${f(lo)}–${f(hi)}';
    if (lo != null) return '${d.short} ≥ ${f(lo)}';
    return '${d.short} ≤ ${f(hi!)}';
  }

  Future<void> _openFilters(List<CompanyLite> companies) async {
    final sectors =
        companies
            .map((c) => c.sector)
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final result = await showModalBottomSheet<_FilterResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FilterSheet(
        sectors: sectors,
        sector: _sector,
        n500: _n500,
        filters: _filters,
      ),
    );
    if (result != null) {
      setState(() {
        _sector = result.sector;
        _n500 = result.n500;
        _filters = result.filters;
        _preset = null;
      });
    }
  }
}

class _ActiveChip extends StatelessWidget {
  const _ActiveChip(this.label, this.onRemove);
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: InputChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onDeleted: onRemove,
      visualDensity: VisualDensity.compact,
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.m,
    required this.c,
    required this.sortKey,
    required this.picked,
    required this.onPick,
  });
  final StockMetrics m;
  final CompanyLite? c;
  final String sortKey;
  final bool picked;
  final ValueChanged<bool> onPick;

  @override
  Widget build(BuildContext context) {
    final keys = [..._rowKeys];
    if (!keys.contains(sortKey)) keys[keys.length - 1] = sortKey;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/company/${Uri.encodeComponent(m.symbol)}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(value: picked, onChanged: (v) => onPick(v ?? false)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c?.name ?? m.symbol,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          metricValue(m.price, '₹'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    Text(
                      [
                        m.symbol,
                        if ((c?.sector ?? '').isNotEmpty) c!.sector,
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final k in keys)
                          _Pill(
                            metricDef(k),
                            m,
                            highlight: k == sortKey,
                            scheme: scheme,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.d, this.m, {required this.highlight, required this.scheme});
  final MetricDef d;
  final StockMetrics m;
  final bool highlight;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final v = d.get(m);
    final isGrowth =
        d.unit == '%' &&
        (d.key == 'rg' || d.key == 'pg' || d.key == 'rgt' || d.key == 'pgt');
    final color = isGrowth && v != null
        ? (v >= 0 ? gainColor : lossColor)
        : (highlight ? scheme.onPrimaryContainer : scheme.onSurface);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${d.short} ',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            TextSpan(
              text: isGrowth ? pct(v) : metricValue(v, d.unit),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- filter sheet

class _FilterResult {
  const _FilterResult(this.sector, this.n500, this.filters);
  final String? sector;
  final bool n500;
  final Map<String, Range> filters;
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.sectors,
    required this.sector,
    required this.n500,
    required this.filters,
  });
  final List<String> sectors;
  final String? sector;
  final bool n500;
  final Map<String, Range> filters;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String? _sector = widget.sector;
  late bool _n500 = widget.n500;
  late final Map<String, (TextEditingController, TextEditingController)> _c = {
    for (final k in _filterKeys)
      k: (
        TextEditingController(text: _fmt(widget.filters[k]?.$1)),
        TextEditingController(text: _fmt(widget.filters[k]?.$2)),
      ),
  };

  static String _fmt(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : '$v');

  @override
  void dispose() {
    for (final (a, b) in _c.values) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, scroll) => Column(
          children: [
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                children: [
                  Text(
                    'Filters',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  DropdownMenu<String?>(
                    initialSelection: _sector,
                    expandedInsets: EdgeInsets.zero,
                    label: Text('Sector'),
                    enableFilter: true,
                    requestFocusOnTap: true,
                    dropdownMenuEntries: [
                      DropdownMenuEntry(value: null, label: 'All sectors'),
                      for (final s in widget.sectors)
                        DropdownMenuEntry(value: s, label: s),
                    ],
                    onSelected: (v) => setState(() => _sector = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Nifty 500 only'),
                    value: _n500,
                    onChanged: (v) => setState(() => _n500 = v),
                  ),
                  const Divider(),
                  for (final k in _filterKeys) _rangeRow(metricDef(k)),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        const _FilterResult(null, false, {}),
                      ),
                      child: Text('Reset all'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () {
                        final f = <String, Range>{};
                        for (final e in _c.entries) {
                          final lo = double.tryParse(e.value.$1.text.trim());
                          final hi = double.tryParse(e.value.$2.text.trim());
                          if (lo != null || hi != null) f[e.key] = (lo, hi);
                        }
                        Navigator.pop(
                          context,
                          _FilterResult(_sector, _n500, f),
                        );
                      },
                      child: Text('Show results'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeRow(MetricDef d) {
    final (lo, hi) = _c[d.key]!;
    final unit = switch (d.unit) {
      'Cr' => '₹ Cr',
      '%' => '%',
      'x' => '×',
      _ => d.unit,
    };
    InputDecoration dec(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
      suffixText: unit,
    );
    const kb = TextInputType.numberWithOptions(decimal: true, signed: true);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Tooltip(
              message: d.help,
              child: Text(d.label, style: const TextStyle(fontSize: 13)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: TextField(
              controller: lo,
              keyboardType: kb,
              decoration: dec('Min'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: TextField(
              controller: hi,
              keyboardType: kb,
              decoration: dec('Max'),
            ),
          ),
        ],
      ),
    );
  }
}
