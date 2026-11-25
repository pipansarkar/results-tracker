import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/models.dart';
import 'repository.dart';

class FirestoreRepository implements Repository {
  FirestoreRepository([FirebaseFirestore? db])
    : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  @override
  bool get isSample => false;

  @override
  Future<List<CompanyLite>> allCompanies() async {
    final doc = await _db.collection('meta').doc('companies').get();
    final list = (doc.data()?['items'] as List?) ?? [];
    return list
        .map((e) => CompanyLite.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Stream<List<FeedItem>> todayFeed() =>
      _db.collection('feed').doc('today').snapshots().map((s) {
        final data = s.data();
        if (data == null) return <FeedItem>[];
        // The pipeline resets the doc each day; ignore a stale one.
        if (data['date'] != dateId(DateTime.now())) return <FeedItem>[];
        return ((data['items'] as List?) ?? [])
            .map((e) => FeedItem.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList()
          ..sort(
            (a, b) => (b.announcedAt ?? DateTime(0)).compareTo(
              a.announcedAt ?? DateTime(0),
            ),
          );
      });

  @override
  Future<List<CalendarDay>> calendar(DateTime from, DateTime to) async {
    final snap = await _db
        .collection('calendar')
        .orderBy(FieldPath.documentId)
        .startAt([weekId(from)])
        .endAt([weekId(to)])
        .get();
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day, 23, 59);
    final events = snap.docs
        .expand((d) => (d.data()['events'] as List? ?? []))
        .map((e) => CalendarEvent.fromMap(Map<String, dynamic>.from(e as Map)))
        .where((e) => !e.date.isBefore(start) && !e.date.isAfter(end));
    return CalendarDay.group(events);
  }

  @override
  Stream<Company?> company(String symbol) => _db
      .collection('companies')
      .doc(symbol)
      .snapshots()
      .map((s) {
        final data = s.data();
        return data == null ? null : Company.fromMap(data);
      });

  @override
  Future<List<Concall>> concalls(String symbol) async {
    final snap = await _db
        .collection('companies')
        .doc(symbol)
        .collection('concalls')
        .orderBy('date', descending: true)
        .limit(12)
        .get();
    return snap.docs.map((d) => Concall.fromMap(d.data())).toList();
  }

  @override
  Future<List<GuidanceItem>> guidance(String symbol) async {
    final snap = await _db
        .collection('companies')
        .doc(symbol)
        .collection('guidance')
        .limit(80)
        .get();
    return snap.docs
        .map((d) => d.data())
        .where((data) => data['status'] != 'superseded')
        .map(GuidanceItem.fromMap)
        .toList();
  }

  @override
  Future<List<NewsItem>> filings(String symbol) async {
    final doc = await _db.collection('news').doc(symbol).get();
    return ((doc.data()?['items'] as List?) ?? [])
        .map((e) => NewsItem.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  @override
  Future<List<StockMetrics>> screener() async {
    final snap = await _db.collection('screener').get();
    return [
      // Read each document once: data() copies the whole document.
      for (final data in snap.docs.map((d) => d.data()))
        for (final e in (data['items'] as List? ?? []))
          StockMetrics.fromMap(
            Map<String, dynamic>.from(e as Map),
            asOf: data['asOf'] as String?,
          ),
    ];
  }

  @override
  Future<List<ActivityItem>> activity(String symbol) async {
    final doc = await _db.collection('activity').doc(symbol).get();
    return [
      for (final e in (doc.data()?['items'] as List? ?? []))
        ActivityItem.fromMap(Map<String, dynamic>.from(e as Map)),
    ]..sort((a, b) => b.date.compareTo(a.date));
  }

  @override
  Future<List<MarketDeal>> marketDeals() async {
    final doc = await _db.collection('deals').doc('latest').get();
    return [
      for (final e in (doc.data()?['items'] as List? ?? []))
        MarketDeal.fromMap(Map<String, dynamic>.from(e as Map)),
    ];
  }

  @override
  Future<Season?> season() async {
    final doc = await _db.collection('meta').doc('season').get();
    final data = doc.data();
    return data == null ? null : Season.fromMap(data);
  }

  @override
  Future<List<OrderWin>> orders() async {
    final doc = await _db.collection('orders').doc('latest').get();
    return [
      for (final e in (doc.data()?['items'] as List? ?? []))
        OrderWin.fromMap(Map<String, dynamic>.from(e as Map)),
    ];
  }

  @override
  Future<IpoBoard> ipos() async {
    final doc = await _db.collection('meta').doc('ipos').get();
    final data = doc.data();
    return data == null ? const IpoBoard() : IpoBoard.fromMap(data);
  }

  @override
  Future<String?> saveScreen(
    String name,
    Map<String, List<double?>> filters, {
    String? sector,
    bool n500 = false,
    List<String> caps = const [],
  }) async {
    final ref = await _db.collection('screens').add({
      'name': name,
      'filters': filters,
      'sector': sector,
      'n500': n500,
      'caps': caps,
      'createdAt': DateTime.now().toIso8601String(),
    });
    return ref.id;
  }
}
