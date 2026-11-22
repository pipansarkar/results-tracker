import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../models/models.dart';

/// Small coloured chip showing a growth percentage.
class GrowthChip extends StatelessWidget {
  const GrowthChip(this.value, {super.key, this.label});
  final double? value;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final color = v == null
        ? Theme.of(context).colorScheme.outline
        : (v >= 0 ? gainColor : lossColor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${label == null ? '' : '$label '}${pct(v)}',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class WatchButton extends ConsumerWidget {
  const WatchButton(this.symbol, {super.key});
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(watchlistsProvider);
    final inLists = [
      for (final e in lists.entries)
        if (e.value.contains(symbol)) e.key,
    ];
    final watched = inLists.isNotEmpty;
    return IconButton(
      tooltip: watched ? 'In ${inLists.join(', ')}' : 'Add to watchlist',
      icon: Icon(
        watched ? Icons.star : Icons.star_border,
        color: watched ? Colors.amber.shade700 : null,
      ),
      onPressed: () {
        final n = ref.read(watchlistsProvider.notifier);
        if (lists.length == 1) {
          n.toggle(symbol);
        } else {
          showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (_) => WatchlistPicker(symbol),
          );
        }
      },
    );
  }
}

/// Bottom sheet: tick which watchlists a stock belongs to.
class WatchlistPicker extends ConsumerWidget {
  const WatchlistPicker(this.symbol, {super.key});
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(watchlistsProvider);
    final n = ref.read(watchlistsProvider.notifier);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Add $symbol to…',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final e in lists.entries)
            CheckboxListTile(
              value: e.value.contains(symbol),
              title: Text(e.key),
              subtitle: Text('${e.value.length} stocks'),
              onChanged: (_) => n.toggle(symbol, list: e.key),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New list'),
            onTap: () async {
              final name = await promptText(context, 'New watchlist', 'Name');
              if (name != null && await n.create(name)) {
                await n.toggle(symbol, list: name.trim());
              }
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Simple text-input dialog. Returns null when cancelled.
Future<String?> promptText(
  BuildContext context,
  String title,
  String hint, {
  String initial = '',
}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, c.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Banner shown while the app runs on generated sample data.
class SampleDataBanner extends ConsumerWidget {
  const SampleDataBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(repositoryProvider).isSample) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        'Sample data: connect Firebase to see live NSE results',
        style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 12),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

Widget asyncError(Object e, StackTrace _) =>
    EmptyState(icon: Icons.cloud_off, message: 'Could not load data.\n$e');

const loading = Center(child: CircularProgressIndicator());

const disclaimerText =
    'For information only. This is not investment advice and makes no buy/sell '
    'recommendations. AI summaries can contain errors, so check the original filing.';

/// Tappable search bar that opens the stock search screen.
class StockSearchBar extends StatelessWidget {
  const StockSearchBar({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: SearchBar(
      hintText: 'Search companies above ₹500 Cr',
      leading: const Icon(Icons.search),
      elevation: const WidgetStatePropertyAll(0),
      onTap: () => GoRouter.of(context).push('/search'),
      // Opens the search screen instead of typing here.
      keyboardType: TextInputType.none,
    ),
  );
}

/// Coloured side label for a concall's type.
class CallTypeLabel extends StatelessWidget {
  const CallTypeLabel(this.c, {super.key});
  final Concall c;

  @override
  Widget build(BuildContext context) {
    final color = switch (c.typeLabel) {
      'Earnings call' => const Color(0xFF2563EB),
      'Analyst meet' => const Color(0xFF7C3AED),
      'Investor call' => const Color(0xFF0891B2),
      'Investor conference' => const Color(0xFFDB2777),
      'AGM' => const Color(0xFF059669),
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        c.typeLabel,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "Record revenue", "Margin up 140 bps"… badge.
class StoryBadge extends StatelessWidget {
  const StoryBadge(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final bad = RegExp(
      r'down|Lowest|loss',
      caseSensitive: false,
    ).hasMatch(text);
    final color = bad ? const Color(0xFFDC2626) : const Color(0xFF16A34A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            bad ? Icons.trending_down : Icons.auto_awesome,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
