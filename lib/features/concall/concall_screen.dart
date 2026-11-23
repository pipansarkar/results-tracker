import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import '../company/company_screen.dart' show GuidanceChangeTile;

/// Detailed summary of one earnings or analyst/investor call.
class ConcallScreen extends ConsumerWidget {
  const ConcallScreen({super.key, required this.symbol, required this.period});
  final String symbol;

  /// The call id ("Q2FY27" or "Q2FY27-1223").
  final String period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calls = ref.watch(concallsProvider(symbol));
    return calls.when(
      loading: () => const Scaffold(body: loading),
      error: (e, s) => Scaffold(appBar: AppBar(), body: asyncError(e, s)),
      data: (list) {
        final c = list.where((e) => e.id == period).firstOrNull;
        if (c == null) {
          return Scaffold(
            appBar: AppBar(title: Text('$symbol · $period')),
            body: const EmptyState(
              icon: Icons.hourglass_empty,
              message:
                  'Summary not ready yet. Transcripts are usually filed '
                  'within 5 working days of the call.',
            ),
          );
        }
        final s = c.forLang('en');
        return DefaultTabController(
          length: 6,
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title, overflow: TextOverflow.ellipsis),
                  Text(
                    [
                      symbol,
                      if (c.date != null) dayFormat.format(c.date!),
                      'Tone: ${c.tone}',
                    ].join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              bottom: const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: 'What changed'),
                  Tab(text: 'Overview'),
                  Tab(text: 'Business'),
                  Tab(text: 'Guidance'),
                  Tab(text: 'Q&A'),
                  Tab(text: 'Risks'),
                ],
              ),
            ),
            body: Column(
              children: [
                const SampleDataBanner(),
                Expanded(
                  child: TabBarView(
                    children: [
                      _Changes(c),
                      _Overview(c, s),
                      _Business(s),
                      _Guidance(c, s),
                      _QaList(s.qa),
                      _Risks(s),
                    ],
                  ),
                ),
                _Footer(c.transcriptUrl),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ----------------------------------------------------------------- helpers

class _Block extends StatelessWidget {
  const _Block(this.title, this.items, {this.icon = Icons.circle, this.color});
  final String title;
  final List<String> items;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final x in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Icon(
                        icon,
                        size: icon == Icons.circle ? 7 : 17,
                        color: c,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(x, style: const TextStyle(height: 1.35)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _listOrEmpty(List<Widget> children, bool hasContent, String message) {
  if (!hasContent) return EmptyState(icon: Icons.notes, message: message);
  return ListView(
    padding: const EdgeInsets.symmetric(vertical: 8),
    children: children,
  );
}

// ------------------------------------------------------------------- tabs

class _Overview extends StatelessWidget {
  const _Overview(this.c, this.s);
  final Concall c;
  final SummaryLang s;

  @override
  Widget build(BuildContext context) {
    final has =
        (s.overview ?? '').isNotEmpty ||
        s.highlights.isNotEmpty ||
        s.financials.isNotEmpty;
    return _listOrEmpty(
      [
        Card(
          color: Theme.of(
            context,
          ).colorScheme.primaryContainer.withValues(alpha: 0.35),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [_ToneChip(c.tone), CallTypeLabel(c)],
                ),
                if ((s.overview ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    s.overview!,
                    style: const TextStyle(fontSize: 15, height: 1.45),
                  ),
                ],
              ],
            ),
          ),
        ),
        _Block('Key takeaways', s.highlights, icon: Icons.bolt),
        _Block('Numbers discussed', s.financials, icon: Icons.bar_chart),
      ],
      has,
      'No overview captured for this call.',
    );
  }
}

class _Business extends StatelessWidget {
  const _Business(this.s);
  final SummaryLang s;

  @override
  Widget build(BuildContext context) {
    final has =
        s.segments.isNotEmpty ||
        s.outlook.isNotEmpty ||
        s.margins.isNotEmpty ||
        s.capex.isNotEmpty ||
        s.balanceSheet.isNotEmpty;
    return _listOrEmpty(
      [
        if (s.segments.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Segments',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final seg in s.segments)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            seg.name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            seg.commentary,
                            style: const TextStyle(height: 1.35),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        _Block('Demand & outlook', s.outlook, icon: Icons.trending_up),
        _Block('Margins & costs', s.margins, icon: Icons.percent),
        _Block('Capex & expansion', s.capex, icon: Icons.factory_outlined),
        _Block(
          'Balance sheet & cash',
          s.balanceSheet,
          icon: Icons.account_balance_outlined,
        ),
      ],
      has,
      'No business detail captured for this call.',
    );
  }
}

class _Guidance extends StatelessWidget {
  const _Guidance(this.c, this.s);
  final Concall c;
  final SummaryLang s;

  @override
  Widget build(BuildContext context) {
    return _listOrEmpty(
      [
        if (c.guidanceDiff.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Guidance tracker · vs ${c.previousPeriod ?? 'previous call'}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final g in c.guidanceDiff) GuidanceChangeTile(g),
                ],
              ),
            ),
          ),
        _Block('What management guided', s.guidance, icon: Icons.flag_outlined),
      ],
      c.guidanceDiff.isNotEmpty || s.guidance.isNotEmpty,
      'No forward-looking guidance in this call.',
    );
  }
}

class _Risks extends StatelessWidget {
  const _Risks(this.s);
  final SummaryLang s;

  @override
  Widget build(BuildContext context) {
    return _listOrEmpty(
      [
        _Block(
          'Red flags',
          s.redFlags,
          icon: Icons.warning_amber_rounded,
          color: lossColor,
        ),
        _Block(
          'Risks & headwinds',
          s.risks,
          icon: Icons.report_outlined,
          color: Colors.amber.shade800,
        ),
        _Block('In management\'s words', s.quotes, icon: Icons.format_quote),
      ],
      s.redFlags.isNotEmpty || s.risks.isNotEmpty || s.quotes.isNotEmpty,
      'No risks or red flags raised in this call.',
    );
  }
}

class _ToneChip extends StatelessWidget {
  const _ToneChip(this.tone);
  final String tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      'positive' => gainColor,
      'cautious' => lossColor,
      _ => Colors.amber.shade800,
    };
    return Chip(
      avatar: Icon(Icons.mood, color: color, size: 18),
      label: Text('Tone: $tone'),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _QaList extends StatefulWidget {
  const _QaList(this.qa);
  final List<QaPair> qa;

  @override
  State<_QaList> createState() => _QaListState();
}

class _QaListState extends State<_QaList> {
  String _q = '';
  String? _topic;
  bool _expandAll = false;

  @override
  Widget build(BuildContext context) {
    final qa = widget.qa;
    if (qa.isEmpty) {
      return const EmptyState(
        icon: Icons.forum_outlined,
        message: 'No Q&A captured.',
      );
    }
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final topics = <String, int>{};
    for (final p in qa) {
      if ((p.topic ?? '').isNotEmpty) {
        topics[p.topic!] = (topics[p.topic!] ?? 0) + 1;
      }
    }
    final topicList = topics.keys.toList()
      ..sort((a, b) => topics[b]!.compareTo(topics[a]!));
    final needle = _q.toLowerCase();
    final shown = [
      for (var i = 0; i < qa.length; i++)
        if ((_topic == null || qa[i].topic == _topic) &&
            (needle.isEmpty ||
                '${qa[i].q} ${qa[i].a} ${qa[i].askedBy}'.toLowerCase().contains(
                  needle,
                )))
          (i + 1, qa[i]),
    ];
    final analysts = {
      for (final p in qa)
        if (p.askedBy.isNotEmpty) p.askedBy,
    }.length;

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${qa.length} questions'
                  '${analysts > 0 ? ' from $analysts analysts' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _expandAll = !_expandAll),
                icon: Icon(
                  _expandAll ? Icons.unfold_less : Icons.unfold_more,
                  size: 18,
                ),
                label: Text(_expandAll ? 'Collapse all' : 'Expand all'),
              ),
            ],
          ),
        ),
        if (qa.length > 6)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search questions & answers',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
          ),
        if (topicList.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: const Text('All topics'),
                    selected: _topic == null,
                    onSelected: (_) => setState(() => _topic = null),
                  ),
                ),
                for (final tp in topicList)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('$tp (${topics[tp]})'),
                      selected: _topic == tp,
                      onSelected: (_) =>
                          setState(() => _topic = _topic == tp ? null : tp),
                    ),
                  ),
              ],
            ),
          ),
        if (shown.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('No questions match.')),
          ),
        for (final (n, p) in shown)
          Card(
            child: ExpansionTile(
              key: ValueKey('qa$n$_expandAll'),
              shape: const Border(),
              initiallyExpanded: _expandAll || qa.length <= 4,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  '$n',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              title: Text(
                p.q,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if ((p.topic ?? '').isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          p.topic!,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    if (p.askedBy.isNotEmpty)
                      Text(p.askedBy, style: t.bodySmall),
                  ],
                ),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((p.answeredBy ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            'Answer: ${p.answeredBy}',
                            style: t.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      Text(p.a, style: const TextStyle(height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// What changed since the previous call: AI comparison + guidance diff.
class _Changes extends StatelessWidget {
  const _Changes(this.c);
  final Concall c;

  @override
  Widget build(BuildContext context) {
    final ch = c.changes;
    final t = Theme.of(context).textTheme;
    if (ch == null && c.guidanceDiff.isEmpty) {
      return const EmptyState(
        icon: Icons.compare_arrows,
        message:
            'Comparison appears once the previous call is summarised too. '
            'Earlier calls are being added automatically.',
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Card(
          color: Theme.of(
            context,
          ).colorScheme.primaryContainer.withValues(alpha: 0.35),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'vs ${c.previousPeriod ?? 'previous call'}',
                  style: t.labelMedium,
                ),
                if (ch != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    ch.summary,
                    style: t.titleMedium?.copyWith(height: 1.35),
                  ),
                  if ((ch.toneShift ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Chip(
                        avatar: const Icon(Icons.mood, size: 18),
                        label: Text('Tone: ${ch.toneShift}'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        if (c.guidanceDiff.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Guidance tracker',
                    style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  for (final g in c.guidanceDiff) GuidanceChangeTile(g),
                ],
              ),
            ),
          ),
        if (ch != null) ...[
          _Block(
            'Guidance shifts (from the call)',
            ch.guidanceShifts,
            icon: Icons.swap_vert,
            color: Colors.indigo,
          ),
          _Block(
            'New this time',
            ch.newTopics,
            icon: Icons.add_circle_outline,
            color: gainColor,
          ),
          _Block(
            'Quietly dropped',
            ch.droppedTopics,
            icon: Icons.visibility_off_outlined,
            color: lossColor,
          ),
        ],
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer(this.url);
  final String? url;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        children: [
          if (url != null)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Open original transcript'),
                onPressed: () => launchUrl(
                  Uri.parse(url!),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Text(disclaimerText, style: TextStyle(fontSize: 10)),
        ],
      ),
    ),
  );
}
