import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

class _StockWeek {
  _StockWeek(this.symbol, this.name);
  final String symbol;
  String name;
  QuarterResult? result;
  List<String> story = const [];
  final List<Concall> calls = [];
  final List<ActivityItem> events = [];
  bool get isEmpty => result == null && calls.isEmpty && events.isEmpty;
}

/// What happened to a watchlist's stocks in the last 7 days.
final weeklyProvider = FutureProvider.family<List<_StockWeek>, String>((
  ref,
  list,
) async {
  final symbols = ref.watch(watchlistsProvider)[list] ?? const [];
  final repo = ref.watch(repositoryProvider);
  final since = DateTime.now().subtract(const Duration(days: 7));
  final out = <_StockWeek>[];
  for (final s in symbols) {
    final w = _StockWeek(s, s);
    final c = await ref.watch(companyProvider(s).future);
    if (c != null) {
      w.name = c.name;
      final q = c.latest;
      if (q?.filedAt != null && q!.filedAt!.isAfter(since)) {
        w.result = q;
        w.story = quarterStory(c.quarters);
      }
    }
    w.calls.addAll(
      (await repo.concalls(
        s,
      )).where((x) => x.date != null && x.date!.isAfter(since)),
    );
    w.events.addAll(
      (await repo.activity(s)).where((a) => a.date.isAfter(since)),
    );
    out.add(w);
  }
  out.sort((a, b) => (b.isEmpty ? 0 : 1).compareTo(a.isEmpty ? 0 : 1));
  return out;
});

class WeeklyScreen extends ConsumerWidget {
  const WeeklyScreen({super.key, required this.list});
  final String list;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(weeklyProvider(list));
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Weekly report'),
            Text(
              '$list · ${dayFormat.format(now.subtract(const Duration(days: 7)))} – ${dayFormat.format(now)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: report.when(
        loading: () => loading,
        error: asyncError,
        data: (weeks) {
          final active = weeks.where((w) => !w.isEmpty).toList();
          final quiet = weeks.where((w) => w.isEmpty).toList();
          final nResults = active.where((w) => w.result != null).length;
          final nCalls = active.fold<int>(0, (a, w) => a + w.calls.length);
          final nOrders = active.fold<int>(
            0,
            (a, w) => a + w.events.where((e) => e.kind == 'order').length,
          );
          final nFlags = active.fold<int>(
            0,
            (a, w) => a + w.events.where((e) => e.kind == 'flag').length,
          );
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Card(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.35),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 20,
                    runSpacing: 10,
                    children: [
                      _Stat('Results', '$nResults'),
                      _Stat('Concalls', '$nCalls'),
                      _Stat('Order wins', '$nOrders'),
                      _Stat(
                        'Red flags',
                        '$nFlags',
                        color: nFlags > 0 ? lossColor : null,
                      ),
                    ],
                  ),
                ),
              ),
              for (final w in active) _WeekCard(w),
              if (quiet.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(
                    'Quiet week: ${quiet.map((w) => w.name).join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      Text(
        value,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    ],
  );
}

class _WeekCard extends StatelessWidget {
  const _WeekCard(this.w);
  final _StockWeek w;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = w.result;
    String line(ActivityItem e) => switch (e.kind) {
      'order' =>
        'Order win ${e.valueCr != null ? crore(e.valueCr) : ''}'
            '${e.pctRevenue != null ? ' (${e.pctRevenue!.toStringAsFixed(1)}% of revenue)' : ''}',
      'rating' =>
        'Credit rating ${e.side ?? ''}: ${[e.who, e.text].whereType<String>().join(' ')}',
      'flag' => '⚠ ${e.text ?? 'Red flag'}',
      'mgmt' =>
        '${e.side == 'exit' ? 'Management exit' : 'Appointment'}: ${(e.detail ?? e.text ?? '').split('.').first}',
      'holding' => e.text ?? 'Shareholding change',
      _ =>
        '${e.kind[0].toUpperCase()}${e.kind.substring(1)} deal: ${e.who ?? ''} '
            '${e.side == 'buy' ? 'bought' : 'sold'}${e.valueCr != null ? ' ${crore(e.valueCr)}' : ''}',
    };
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/company/${Uri.encodeComponent(w.symbol)}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                w.name,
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (r != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${r.period} results: revenue ${crore(r.revenue)}, profit ${crore(r.pat)}'
                  '${r.reaction != null ? ' · stock ${pct(r.reaction)}' : ''}',
                ),
                if (w.story.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (final b in w.story) StoryBadge(b)],
                    ),
                  ),
              ],
              for (final c in w.calls)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      CallTypeLabel(c),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (c.forLang('en').overview ??
                                  c.changes?.summary ??
                                  'Summary ready')
                              .split('. ')
                              .first,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              for (final e in w.events.take(6))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '•  ${line(e)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
