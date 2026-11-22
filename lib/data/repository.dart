import '../models/models.dart';

/// Read-only data source for the app. Two implementations:
/// [SeedRepository] (offline sample data) and [FirestoreRepository].
///
/// Methods are shaped so each screen costs ~1 Firestore read, to stay
/// inside the free Spark plan quota.
abstract class Repository {
  bool get isSample;

  /// All tracked companies (one doc: meta/companies).
  Future<List<CompanyLite>> allCompanies();

  /// Results announced today (one doc: feed/today).
  Stream<List<FeedItem>> todayFeed();

  /// Calendar days between [from] and [to] inclusive (one doc per week),
  /// covering both past and upcoming events.
  Future<List<CalendarDay>> calendar(DateTime from, DateTime to);

  /// Company with quarterly history (one doc).
  Stream<Company?> company(String symbol);

  /// Concall summaries, newest first.
  Future<List<Concall>> concalls(String symbol);

  /// Guidance statements tracked against actuals.
  Future<List<GuidanceItem>> guidance(String symbol);

  /// The company's latest NSE announcements, newest first (one doc).
  Future<List<NewsItem>> filings(String symbol);

  /// Ratios for every stock (a few screener/{n} docs).
  Future<List<StockMetrics>> screener();

  /// Deals, ownership changes and red flags for one company (one doc).
  Future<List<ActivityItem>> activity(String symbol);

  /// Market-wide deals of the last few days (one doc).
  Future<List<MarketDeal>> marketDeals();

  /// Results-season scoreboard (one doc), or null before the season starts.
  Future<Season?> season();
}

String dateId(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Calendar docs are one per week, keyed by that week's Monday.
String weekId(DateTime d) => dateId(
  DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1)),
);
