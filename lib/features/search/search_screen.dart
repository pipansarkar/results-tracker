import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.pick = false});

  /// Pick mode: tapping a stock returns its symbol (used by Compare).
  final bool pick;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String _q = '';

  /// Exact symbol, then prefix matches, then anywhere in the name.
  static List<CompanyLite> _rank(List<CompanyLite> all, String q) {
    if (q.isEmpty) return all.take(100).toList();
    int score(CompanyLite c) {
      final s = c.symbol.toLowerCase(), n = c.name.toLowerCase();
      if (s == q) return 0;
      if (s.startsWith(q)) return 1;
      if (n.startsWith(q)) return 2;
      if (n.split(RegExp(r'\s+')).any((w) => w.startsWith(q))) return 3;
      if (s.contains(q) || n.contains(q)) return 4;
      return 99;
    }

    final hits =
        [
          for (final c in all)
            if (score(c) < 99) (score(c), c),
        ]..sort(
          (a, b) => a.$1 != b.$1
              ? a.$1.compareTo(b.$1)
              : a.$2.name.compareTo(b.$2.name),
        );
    return hits.take(100).map((h) => h.$2).toList();
  }

  @override
  Widget build(BuildContext context) {
    final companies = ref.watch(companiesProvider);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search company or NSE symbol',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
        ),
      ),
      body: companies.when(
        loading: () => loading,
        error: asyncError,
        data: (all) {
          final list = _rank(all, _q);
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.search_off,
              message: 'No matching company.',
            );
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final c = list[i];
              return ListTile(
                title: Text(c.name),
                subtitle: Text('${c.symbol} · ${c.sector}'),
                trailing: widget.pick
                    ? const Icon(Icons.add_circle_outline)
                    : WatchButton(c.symbol),
                onTap: () => widget.pick
                    ? context.pop(c.symbol)
                    : context.push('/company/${Uri.encodeComponent(c.symbol)}'),
              );
            },
          );
        },
      ),
    );
  }
}
