import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

class ConcallScreen extends ConsumerWidget {
  const ConcallScreen({super.key, required this.symbol, required this.period});
  final String symbol;
  final String period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calls = ref.watch(concallsProvider(symbol));
    final lang = ref.watch(languageProvider);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text('$symbol · $period concall'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Highlights'),
              Tab(text: 'Guidance'),
              Tab(text: 'Q&A'),
              Tab(text: 'Red flags'),
            ],
          ),
        ),
        body: calls.when(
          loading: () => loading,
          error: asyncError,
          data: (list) {
            final c = list.where((e) => e.period == period).firstOrNull;
            if (c == null) {
              return const EmptyState(
                icon: Icons.hourglass_empty,
                message:
                    'Summary not ready yet. Transcripts are usually filed '
                    'within 5 working days of the call.',
              );
            }
            final s = c.forLang(lang);
            return Column(
              children: [
                const SampleDataBanner(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _ToneChip(c.tone, c.toneChange),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: [
                          for (final e in languageNames.entries)
                            ButtonSegment(value: e.key, label: Text(e.value)),
                        ],
                        selected: {lang},
                        onSelectionChanged: (v) =>
                            ref.read(languageProvider.notifier).set(v.first),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _Bullets(s.highlights, Icons.bolt),
                      _Bullets(s.guidance, Icons.flag_outlined),
                      _QaList(s.qa),
                      _Bullets(
                        s.redFlags,
                        Icons.warning_amber,
                        color: lossColor,
                        empty: 'No red flags spotted in this call.',
                      ),
                    ],
                  ),
                ),
                _Footer(c.transcriptUrl),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ToneChip extends StatelessWidget {
  const _ToneChip(this.tone, this.change);
  final String tone;
  final String? change;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      'positive' => gainColor,
      'cautious' => lossColor,
      _ => Colors.amber.shade800,
    };
    return Tooltip(
      message: change ?? '',
      child: Chip(
        avatar: Icon(Icons.mood, color: color, size: 18),
        label: Text('Tone: $tone'),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _Bullets extends StatelessWidget {
  const _Bullets(
    this.items,
    this.icon, {
    this.color,
    this.empty = 'Nothing here.',
  });
  final List<String> items;
  final IconData icon;
  final Color? color;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return EmptyState(icon: icon, message: empty);
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => ListTile(
        leading: Icon(
          icon,
          color: color ?? Theme.of(context).colorScheme.primary,
        ),
        title: Text(items[i]),
      ),
    );
  }
}

class _QaList extends StatelessWidget {
  const _QaList(this.qa);
  final List<QaPair> qa;

  @override
  Widget build(BuildContext context) {
    if (qa.isEmpty) {
      return const EmptyState(
        icon: Icons.forum_outlined,
        message: 'No Q&A captured.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final p in qa)
          Card(
            child: ExpansionTile(
              shape: const Border(),
              leading: const Icon(Icons.help_outline),
              title: Text(
                p.q,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                Align(alignment: Alignment.centerLeft, child: Text(p.a)),
              ],
            ),
          ),
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
