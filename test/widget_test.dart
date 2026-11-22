import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:results_tracker/app.dart';
import 'package:results_tracker/data/media_news.dart';
import 'package:results_tracker/data/providers.dart';
import 'package:results_tracker/data/seed_repository.dart';
import 'package:results_tracker/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        repositoryProvider.overrideWithValue(SeedRepository()),
        mediaNewsServiceProvider.overrideWithValue(_FakeMedia()),
      ],
      child: const ResultsTrackerApp(),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeMedia extends MediaNews {
  @override
  Future<List<NewsItem>> forCompany(String name, String symbol) async => [
    NewsItem(
      date: DateTime.now().subtract(const Duration(hours: 3)),
      title: '$name shares rise after quarterly results',
      url: 'https://example.com/a',
      source: 'Example Times',
    ),
  ];
}

const _rss = """<?xml version="1.0"?><rss><channel>
<item><title>TCS Q2 profit up 9% - Business Daily</title>
<link>https://news.example/1</link><pubDate>Sat, 21 Nov 2026 10:30:00 GMT</pubDate>
<source url="https://bd.example">Business Daily</source></item>
<item><title>TCS wins large deal - Market Wire</title>
<link>https://news.example/2</link><pubDate>Sun, 22 Nov 2026 04:00:00 GMT</pubDate>
<source url="https://mw.example">Market Wire</source></item>
</channel></rss>""";

void main() {
  test('Google News RSS parsing', () {
    final items = MediaNews.parseRss(_rss);
    expect(items.length, 2);
    expect(items.first.title, 'TCS wins large deal'); // newest first
    expect(items.first.source, 'Market Wire');
    expect(items.last.title, 'TCS Q2 profit up 9%');
  });

  group('models', () {
    test('pctChange', () {
      expect(pctChange(110, 100), closeTo(10, 1e-9));
      expect(pctChange(-50, -100), closeTo(50, 1e-9));
      expect(pctChange(1, 0), isNull);
      expect(pctChange(null, 5), isNull);
    });

    test('topicForSymbol sanitises symbols', () {
      expect(topicForSymbol('M&M'), 'stock_M_M');
      expect(topicForSymbol('BAJAJ-AUTO'), 'stock_BAJAJ-AUTO');
    });

    test('Indian fiscal quarter labels', () {
      expect(SeedRepository.quarterLabel(DateTime(2026, 9, 30)), 'Q2FY27');
      expect(SeedRepository.quarterLabel(DateTime(2026, 12, 31)), 'Q3FY27');
      expect(SeedRepository.quarterLabel(DateTime(2027, 3, 31)), 'Q4FY27');
      expect(SeedRepository.quarterLabel(DateTime(2026, 6, 30)), 'Q1FY27');
    });
  });

  testWidgets('Today screen lists announced results', (tester) async {
    await pumpApp(tester);
    expect(find.text("Today's Results"), findsOneWidget);
    expect(find.textContaining('Sample data'), findsOneWidget);
    expect(find.text('HDFC Bank'), findsOneWidget);
  });

  testWidgets('Company page, watchlist and concall summary', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('HDFC Bank'));
    await tester.pumpAndSettle();
    expect(find.text('Revenue'), findsWidgets);
    expect(find.text('Quarterly history'), findsNothing); // below the fold
    // Results tab extras at the top: key ratios and price reaction.
    expect(find.text('Key ratios'), findsOneWidget);
    expect(find.text('Share price reaction to these results'), findsOneWidget);
    expect(find.textContaining('at a glance'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Quarterly history'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.text('Quarterly history'), findsOneWidget);

    // Add to watchlist from the app bar.
    await tester.tap(find.byTooltip('Add to watchlist').first);
    await tester.pump();
    expect(find.byTooltip('In My watchlist'), findsWidgets);

    Future<void> tapTab(String name) async {
      final tab = find.widgetWithText(Tab, name).first;
      await tester.ensureVisible(tab);
      await tester.pumpAndSettle();
      await tester.tap(tab);
      await tester.pumpAndSettle();
    }

    // Financials tab: balance sheet + cash flow.
    await tapTab('Financials');
    expect(find.text('Balance sheet'), findsOneWidget);
    expect(find.text('Cash flow'), findsOneWidget);

    // Ownership tab: shareholding, pledge, deals & red flags.
    await tapTab('Ownership');
    expect(find.text('Who owns the company'), findsOneWidget);
    expect(find.text('Promoters'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Deals, stake changes & red flags'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.textContaining('Block deal'), findsWidgets);

    // Guidance tab: credibility + latest guidance changes (diff).
    await tapTab('Guidance');
    expect(find.text('Management credibility'), findsOneWidget);
    expect(find.text('Cut'), findsWidgets);

    // News tab: media headline + NSE filings.
    await tapTab('News');
    expect(
      find.textContaining('shares rise after quarterly results'),
      findsOneWidget,
    );
    expect(find.text('NSE filing'), findsWidgets);
    await tester.tap(find.text('NSE filings'));
    await tester.pumpAndSettle();
    expect(find.textContaining('shares rise'), findsNothing);

    // Concalls: earnings call + analyst meet, each labelled.
    await tapTab('Concalls');
    expect(find.text('Earnings call'), findsWidgets);
    expect(find.text('Analyst meet'), findsOneWidget);
    await tester.tap(find.text('Earnings call').first);
    await tester.pumpAndSettle();
    // What changed (AI + guidance diff).
    expect(find.textContaining('Growth guidance trimmed'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Quietly dropped'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.text('Quietly dropped'), findsOneWidget);
    // Detailed sections.
    await tapTab('Overview');
    expect(find.textContaining('delivered a steady'), findsOneWidget);
    expect(find.text('Key takeaways'), findsOneWidget);
    await tapTab('Business');
    expect(find.text('Segments'), findsOneWidget);
    expect(find.text('Capex & expansion'), findsOneWidget);
    await tapTab('Risks');
    expect(find.text('Risks & headwinds'), findsOneWidget);
  });

  testWidgets('Season scoreboard and big deals', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.textContaining('season').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('companies have reported'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Biggest profit growth'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.text('Biggest profit growth'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Big deals'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Block deal'), findsWidgets);
  });

  testWidgets('Calendar shows upcoming and past events', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    expect(find.text('Results Calendar'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.textContaining('Concall'), findsWidgets);

    // Past tab: already-reported results and summarised concalls.
    await tester.tap(find.text('Past'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reported'), findsWidgets);
    expect(find.textContaining('summary ready'), findsWidgets);

    // Investor meets filter.
    await tester.ensureVisible(find.text('Investor meets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Investor meets'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Investor conference'), findsWidgets);
    expect(find.textContaining('Reported'), findsNothing);

    await tester.tap(find.text('Watchlist').last);
    await tester.pumpAndSettle();
    expect(find.text('Find a stock'), findsOneWidget);
  });

  testWidgets('Search bar finds a stock by name', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byType(SearchBar));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'infos');
    await tester.pumpAndSettle();
    expect(find.text('Infosys'), findsOneWidget);
    expect(find.text('Wipro'), findsNothing);
  });

  testWidgets('Screener presets, filters and compare', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Screener'));
    await tester.pumpAndSettle();
    expect(find.textContaining('20 stocks'), findsOneWidget);

    // A preset narrows the list and changes the sort.
    await tester.tap(find.text('Value'));
    await tester.pumpAndSettle();
    final large = find.textContaining(RegExp(r'^\d+ stocks$'));
    expect(large, findsOneWidget);
    expect((tester.widget<Text>(large)).data, isNot('20 stocks'));
    expect(find.textContaining('ROE ≥'), findsOneWidget); // active chip
    expect(find.textContaining('Sorted by P/E ↑'), findsOneWidget);

    // Pick two stocks -> Compare.
    await tester.tap(find.text('Value')); // clear preset
    await tester.pumpAndSettle();
    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.at(0));
    await tester.tap(boxes.at(1));
    await tester.pumpAndSettle();
    expect(find.text('Compare 2'), findsOneWidget);
    await tester.tap(find.text('Compare 2'));
    await tester.pumpAndSettle();
    expect(find.text('Key numbers'), findsOneWidget);
    expect(find.text('VALUATION'), findsOneWidget);
    expect(find.text('ROE'), findsWidgets);
  });

  testWidgets('Company page shows key ratios', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('HDFC Bank'));
    await tester.pumpAndSettle();
    expect(find.text('Key ratios'), findsOneWidget);
    expect(find.text('P/E'), findsOneWidget);
    expect(find.text('ROE'), findsOneWidget);
  });

  testWidgets('Events tab, IPOs, order wins and multiple watchlists', (tester) async {
    await pumpApp(tester);
    // Company: Events tab with order book, orders, ratings, dividends.
    await tester.tap(find.text('HDFC Bank'));
    await tester.pumpAndSettle();
    final events = find.widgetWithText(Tab, 'Events');
    await tester.ensureVisible(events);
    await tester.tap(events);
    await tester.pumpAndSettle();
    expect(find.text('Order book'), findsWidgets);
    expect(find.text('Order wins'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // IPOs.
    await tester.tap(find.text('IPOs'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bright Energy'), findsOneWidget);
    await tester.tap(find.textContaining('Bright Energy'));
    await tester.pumpAndSettle();
    expect(find.text('Subscription by category'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Order wins feed.
    await tester.tap(find.text('Order wins'));
    await tester.pumpAndSettle();
    expect(find.textContaining('of annual revenue'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Multiple watchlists: create a second list.
    await tester.tap(find.text('Watchlist').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New list'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Defence');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Defence (0)'), findsOneWidget);
    expect(find.textContaining('My watchlist'), findsWidgets);
  });
}
