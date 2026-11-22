import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:results_tracker/app.dart';
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
      ],
      child: const ResultsTrackerApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
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
    expect(find.text('Quarterly table'), findsNothing); // below the fold
    await tester.scrollUntilVisible(
      find.text('Quarterly table'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.text('Quarterly table'), findsOneWidget);

    // Add to watchlist from the app bar.
    await tester.tap(find.byTooltip('Add to watchlist').first);
    await tester.pump();
    expect(find.byTooltip('Remove from watchlist'), findsWidgets);

    // Guidance tab shows the credibility score.
    await tester.tap(find.text('Guidance'));
    await tester.pumpAndSettle();
    expect(find.text('Management credibility'), findsOneWidget);

    // Concall tab -> summary, switch to Bengali.
    await tester.tap(find.text('Concalls'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('earnings call').first);
    await tester.pumpAndSettle();
    expect(find.text('Highlights'), findsOneWidget);
    expect(find.textContaining('[Sample] HDFC Bank reported'), findsOneWidget);
    await tester.tap(find.text('বাংলা'));
    await tester.pumpAndSettle();
    expect(find.textContaining('[নমুনা]'), findsWidgets);
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
}
