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
    final watched = ref.watch(watchlistProvider).contains(symbol);
    return IconButton(
      tooltip: watched ? 'Remove from watchlist' : 'Add to watchlist',
      icon: Icon(
        watched ? Icons.star : Icons.star_border,
        color: watched ? Colors.amber.shade700 : null,
      ),
      onPressed: () => ref.read(watchlistProvider.notifier).toggle(symbol),
    );
  }
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
