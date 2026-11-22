import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

enum _Source { all, media, exchange }

/// News for one company: media headlines (Google News) and official
/// exchange filings (NSE announcements).
class NewsTab extends ConsumerStatefulWidget {
  const NewsTab({super.key, required this.symbol, required this.name});
  final String symbol;
  final String name;

  @override
  ConsumerState<NewsTab> createState() => _NewsTabState();
}

class _NewsTabState extends ConsumerState<NewsTab> {
  _Source _source = _Source.all;

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(mediaNewsProvider((widget.symbol, widget.name)));
    final filings = ref.watch(filingsProvider(widget.symbol));

    final items = <NewsItem>[
      if (_source != _Source.exchange) ...?media.value,
      if (_source != _Source.media) ...?filings.value,
    ]..sort((a, b) => b.date.compareTo(a.date));
    final stillLoading =
        (_source != _Source.exchange && media.isLoading) ||
        (_source != _Source.media && filings.isLoading);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(mediaNewsProvider((widget.symbol, widget.name)));
        ref.invalidate(filingsProvider(widget.symbol));
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<_Source>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: _Source.all, label: Text('All')),
                ButtonSegment(value: _Source.media, label: Text('In the news')),
                ButtonSegment(
                  value: _Source.exchange,
                  label: Text('NSE filings'),
                ),
              ],
              selected: {_source},
              onSelectionChanged: (v) => setState(() => _source = v.first),
            ),
          ),
          if (stillLoading && items.isEmpty)
            const Padding(padding: EdgeInsets.all(40), child: loading)
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.newspaper,
              message: media.hasError && _source != _Source.exchange
                  ? 'Could not load news. Check your connection and pull to refresh.'
                  : 'No news yet for ${widget.name}.',
            )
          else
            for (final n in items) _NewsCard(n),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              'Headlines from Google News; filings from NSE. Tap to read the '
              'full story on the publisher\'s site.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _NewsCard extends StatelessWidget {
  const _NewsCard(this.n);
  final NewsItem n;

  static String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes.clamp(1, 59)}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isFiling = n.source == 'NSE';
    final url = n.url;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: url == null
            ? null
            : () => launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalApplication,
              ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isFiling
                          ? scheme.secondaryContainer
                          : scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      isFiling ? 'NSE filing' : n.source,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isFiling
                            ? scheme.onSecondaryContainer
                            : scheme.onPrimaryContainer,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _ago(n.date),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                n.title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  height: 1.3,
                ),
              ),
              if (n.text != null && n.text!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  n.text!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              if (isFiling && url != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.picture_as_pdf_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'View filing',
                      style: TextStyle(color: scheme.primary, fontSize: 13),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
