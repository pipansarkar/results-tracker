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
      .map((s) => s.data() == null ? null : Company.fromMap(s.data()!));

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
        .where((d) => d.data()['status'] != 'superseded')
        .map((d) => GuidanceItem.fromMap(d.data()))
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
      for (final d in snap.docs)
        for (final e in (d.data()['items'] as List? ?? []))
          StockMetrics.fromMap(
            Map<String, dynamic>.from(e as Map),
            asOf: d.data()['asOf'] as String?,
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
    return doc.data() == null ? null : Season.fromMap(doc.data()!);
  }
}
