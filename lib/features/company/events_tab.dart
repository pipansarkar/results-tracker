import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import 'section.dart';

/// Order book & order wins, credit ratings, management changes, dividends
/// and corporate actions for one company.
class EventsTab extends ConsumerWidget {
  const EventsTab(this.c, {super.key});
  final Company c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity =
        ref.watch(activityProvider(c.symbol)).value ?? const <ActivityItem>[];
    final calls =
        ref.watch(concallsProvider(c.symbol)).value ?? const <Concall>[];
    final metrics = ref.watch(metricsProvider(c.symbol));
    final orders = activity.where((a) => a.kind == 'order').toList();
    final ratings = activity.where((a) => a.kind == 'rating').toList();
    final mgmt = activity
        .where(
          (a) =>
              a.kind == 'mgmt' ||
              (a.kind == 'flag' && (a.text ?? '').contains('exit')),
        )
        .toList();
    final bookCall = calls
        .where(
          (x) =>
              !x.isDocument &&
              x.forLang('en').orderBook != null &&
              !x.forLang('en').orderBook!.isEmpty,
        )
        .firstOrNull;

    final nothing =
        orders.isEmpty &&
        ratings.isEmpty &&
        mgmt.isEmpty &&
        c.dividends.isEmpty &&
        c.corpActions.isEmpty &&
        bookCall == null;
    if (nothing) {
      return const EmptyState(
        icon: Icons.event_note_outlined,
        message:
            'Orders, ratings, management changes and dividends appear here as '
            'the company files them.',
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (bookCall != null) _OrderBookCard(bookCall, orders, c),
        if (orders.isNotEmpty)
          Section(
            title: 'Order wins',
            trailing: Text(
              '${orders.length} recent',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            child: Column(
              children: [for (final o in orders.take(15)) OrderTile(o)],
            ),
          ),
        if (ratings.isNotEmpty)
          Section(
            title: 'Credit ratings',
            child: Column(
              children: [for (final r in ratings.take(12)) _RatingTile(r)],
            ),
          ),
        if (mgmt.isNotEmpty)
          Section(
            title: 'Management changes',
            child: Column(
              children: [for (final m in mgmt.take(15)) _MgmtTile(m)],
            ),
          ),
        if (c.dividends.isNotEmpty) _Dividends(c, metrics),
        if (c.corpActions.any(
          (a) => !a.subject.toLowerCase().contains('dividend'),
        ))
          Section(
            title: 'Other corporate actions',
            child: Column(
              children: [
                for (final a
                    in c.corpActions
                        .where(
                          (a) => !a.subject.toLowerCase().contains('dividend'),
                        )
                        .take(10))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.card_giftcard),
                    title: Text(a.subject),
                    trailing: Text(
                      dayFormat.format(a.exDate),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OrderBookCard extends StatelessWidget {
  const _OrderBookCard(this.call, this.orders, this.c);
  final Concall call;
  final List<ActivityItem> orders;
  final Company c;

  @override
  Widget build(BuildContext context) {
    final ob = call.forLang('en').orderBook!;
    final scheme = Theme.of(context).colorScheme;
    // Order wins announced since that call (not yet in the reported book).
    final since = call.date == null
        ? const <ActivityItem>[]
        : orders
              .where((o) => o.date.isAfter(call.date!) && o.valueCr != null)
              .toList();
    final sinceValue = since.fold<double>(0, (a, o) => a + o.valueCr!);
    final ttmRev = c.quarters
        .take(4)
        .fold<double>(0, (a, q) => a + (q.revenue ?? 0));
    Widget stat(String label, String value) => Container(
      width: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          FittedBox(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
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
              'Order book',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'From the ${call.period} call${ob.asOf != null ? ' · as of ${ob.asOf}' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (ob.valueCr != null) stat('Order book', crore(ob.valueCr)),
                if (ob.bookToBill != null)
                  stat('Book-to-bill', '${ob.bookToBill!.toStringAsFixed(1)}x')
                else if (ob.valueCr != null && ttmRev > 0)
                  stat(
                    'Book ÷ TTM revenue',
                    '${(ob.valueCr! / ttmRev).toStringAsFixed(1)}x',
                  ),
                if (ob.inflowsCr != null)
                  stat('Order inflows', crore(ob.inflowsCr)),
                if (ob.executionYears != null)
                  stat(
                    'Execution',
                    '${ob.executionYears!.toStringAsFixed(1)} yrs',
                  ),
                if (since.isNotEmpty)
                  stat(
                    'Won since the call',
                    '${crore(sinceValue)} (${since.length})',
                  ),
              ],
            ),
            for (final x in ob.commentary)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('•  $x', style: const TextStyle(height: 1.35)),
              ),
          ],
        ),
      ),
    );
  }
}

/// One order win.
class OrderTile extends StatelessWidget {
  const OrderTile(this.o, {super.key, this.company});
  final ActivityItem o;
  final String? company;

  @override
  Widget build(BuildContext context) {
    final big = (o.pctRevenue ?? 0) >= 5;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: gainColor.withValues(alpha: big ? 0.25 : 0.12),
        child: const Icon(
          Icons.assignment_turned_in_outlined,
          color: gainColor,
        ),
      ),
      title: Text(
        [
          if (company != null) company!,
          o.valueCr != null ? crore(o.valueCr) : 'Order win',
        ].join(' · '),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        [
          if (o.pctRevenue != null)
            '${o.pctRevenue!.toStringAsFixed(1)}% of annual revenue',
          if ((o.who ?? '').isNotEmpty) 'Client: ${o.who}',
          if ((o.text ?? '').isNotEmpty) o.text!,
          if ((o.detail ?? '').isNotEmpty) 'Execution: ${o.detail}',
        ].join('\n'),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        dayFormat.format(o.date),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: o.url == null
          ? null
          : () => launchUrl(
              Uri.parse(o.url!),
              mode: LaunchMode.externalApplication,
            ),
    );
  }
}

class _RatingTile extends StatelessWidget {
  const _RatingTile(this.r);
  final ActivityItem r;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (r.side) {
      'upgrade' => (Icons.arrow_upward, gainColor, 'Upgrade'),
      'downgrade' => (Icons.arrow_downward, lossColor, 'Downgrade'),
      'assigned' => (Icons.fiber_new_outlined, Colors.blue, 'Assigned'),
      'withdrawn' => (Icons.block, Colors.grey, 'Withdrawn'),
      'outlook_change' => (
        Icons.swap_vert,
        Colors.amber.shade800,
        'Outlook change',
      ),
      _ => (Icons.check, Colors.grey, 'Reaffirmed'),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(icon, color: color),
      ),
      title: Text(
        [r.who, r.text].whereType<String>().join(' · '),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        [
          label,
          if (r.previous != null) 'from ${r.previous}',
          if (r.outlook != null) 'Outlook: ${r.outlook}',
          if (r.detail != null) r.detail!,
        ].join(' · '),
      ),
      trailing: Text(
        dayFormat.format(r.date),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: r.url == null
          ? null
          : () => launchUrl(
              Uri.parse(r.url!),
              mode: LaunchMode.externalApplication,
            ),
    );
  }
}

class _MgmtTile extends StatelessWidget {
  const _MgmtTile(this.m);
  final ActivityItem m;

  @override
  Widget build(BuildContext context) {
    final exit = m.side == 'exit' || m.kind == 'flag';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: (exit ? lossColor : Colors.blue).withValues(
          alpha: 0.12,
        ),
        child: Icon(
          exit ? Icons.person_remove_outlined : Icons.person_add_alt,
          color: exit ? lossColor : Colors.blue,
        ),
      ),
      title: Text(
        exit ? 'Exit / resignation' : 'Appointment',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        m.detail ?? m.text ?? '',
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        dayFormat.format(m.date),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: m.url == null
          ? null
          : () => launchUrl(
              Uri.parse(m.url!),
              mode: LaunchMode.externalApplication,
            ),
    );
  }
}

class _Dividends extends StatelessWidget {
  const _Dividends(this.c, this.m);
  final Company c;
  final StockMetrics? m;

  @override
  Widget build(BuildContext context) {
    // Per fiscal year (Apr-Mar) totals.
    final byFy = <String, double>{};
    for (final d in c.dividends) {
      final fy = d.exDate.month >= 4 ? d.exDate.year + 1 : d.exDate.year;
      byFy['FY${(fy % 100).toString().padLeft(2, '0')}'] =
          (byFy['FY${(fy % 100).toString().padLeft(2, '0')}'] ?? 0) + d.amount;
    }
    return Section(
      title: 'Dividends',
      trailing: m?.dividendYield == null
          ? null
          : Text(
              'Yield ${m!.dividendYield!.toStringAsFixed(2)}% (TTM)',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: gainColor,
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in byFy.entries.take(4))
                Chip(
                  label: Text('${e.key}: ₹${e.value.toStringAsFixed(2)}'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (final d in c.dividends.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${d.kind[0].toUpperCase()}${d.kind.substring(1)} dividend',
                    ),
                  ),
                  Text(
                    '₹${d.amount.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'ex ${dayFormat.format(d.exDate)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
