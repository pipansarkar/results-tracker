import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/home_widget_sync.dart';
import 'core/theme.dart';
import 'data/providers.dart';
import 'features/calendar/calendar_screen.dart';
import 'features/company/company_screen.dart';
import 'features/compare/compare_screen.dart';
import 'features/concall/concall_screen.dart';
import 'features/deals/deals_screen.dart';
import 'features/ipo/ipo_screen.dart';
import 'features/orders/orders_screen.dart';
import 'features/weekly/weekly_screen.dart';
import 'features/screener/screener_screen.dart';
import 'features/search/search_screen.dart';
import 'features/season/season_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/today/today_screen.dart';
import 'features/watchlist/watchlist_screen.dart';

GoRouter buildRouter() => GoRouter(
  initialLocation: '/today',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/today', builder: (_, _) => const TodayScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/calendar',
              builder: (_, _) => const CalendarScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/screener',
              builder: (_, _) => const ScreenerScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/watchlist',
              builder: (_, _) => const WatchlistScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/more', builder: (_, _) => const SettingsScreen()),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/search',
      builder: (_, s) =>
          SearchScreen(pick: s.uri.queryParameters['pick'] == '1'),
    ),
    GoRoute(path: '/season', builder: (_, _) => const SeasonScreen()),
    GoRoute(path: '/deals', builder: (_, _) => const DealsScreen()),
    GoRoute(path: '/orders', builder: (_, _) => const OrdersScreen()),
    GoRoute(path: '/ipos', builder: (_, _) => const IpoScreen()),
    GoRoute(
      path: '/ipo/:symbol',
      builder: (_, s) => IpoDetailScreen(symbol: s.pathParameters['symbol']!),
    ),
    GoRoute(
      path: '/weekly',
      builder: (_, s) =>
          WeeklyScreen(list: s.uri.queryParameters['list'] ?? ''),
    ),
    GoRoute(
      path: '/compare',
      builder: (_, s) => CompareScreen(
        initial: (s.uri.queryParameters['s'] ?? '')
            .split(',')
            .where((x) => x.isNotEmpty)
            .toList(),
      ),
    ),
    GoRoute(
      path: '/company/:symbol',
      builder: (_, s) => CompanyScreen(symbol: s.pathParameters['symbol']!),
      routes: [
        GoRoute(
          path: 'concall/:period',
          builder: (_, s) => ConcallScreen(
            symbol: s.pathParameters['symbol']!,
            period: s.pathParameters['period']!,
          ),
        ),
      ],
    ),
  ],
);

class _Shell extends StatelessWidget {
  const _Shell(this.shell);
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: shell,
    bottomNavigationBar: NavigationBar(
      selectedIndex: shell.currentIndex,
      onDestinationSelected: (i) =>
          shell.goBranch(i, initialLocation: i == shell.currentIndex),
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.today_outlined),
          selectedIcon: Icon(Icons.today),
          label: 'Today',
        ),
        NavigationDestination(
          icon: Icon(Icons.calendar_month_outlined),
          selectedIcon: Icon(Icons.calendar_month),
          label: 'Calendar',
        ),
        NavigationDestination(
          icon: Icon(Icons.filter_alt_outlined),
          selectedIcon: Icon(Icons.filter_alt),
          label: 'Screener',
        ),
        NavigationDestination(
          icon: Icon(Icons.star_border),
          selectedIcon: Icon(Icons.star),
          label: 'Watchlist',
        ),
        NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
      ],
    ),
  );
}

class ResultsTrackerApp extends ConsumerStatefulWidget {
  const ResultsTrackerApp({super.key});

  @override
  ConsumerState<ResultsTrackerApp> createState() => _ResultsTrackerAppState();
}

class _ResultsTrackerAppState extends ConsumerState<ResultsTrackerApp> {
  late final _router = buildRouter();

  void _syncWidget() {
    syncHomeWidget(
      today: ref.read(todayFeedProvider).value ?? const [],
      calendar: ref.read(calendarProvider).value ?? const [],
      watchlist: ref.read(watchlistProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the Android home-screen widget fresh.
    ref.listen(todayFeedProvider, (_, _) => _syncWidget());
    ref.listen(calendarProvider, (_, _) => _syncWidget());
    ref.listen(watchlistProvider, (_, _) => _syncWidget());
    return MaterialApp.router(
      title: 'Quarterly Results & Concall Tracker',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: _router,
    );
  }
}
