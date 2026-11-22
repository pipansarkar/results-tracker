// Data models. Field names match the Firestore documents written by the
// Python pipeline in backend/ (see backend/firestore_io.py).
// All money values are in ₹ crore.

double? _d(dynamic v) => v == null ? null : (v as num).toDouble();
List<String> _strings(dynamic v) =>
    v == null ? const [] : List<String>.from(v as List);

/// FCM topic names only allow [a-zA-Z0-9-_.~%]. Symbols like "M&M" need
/// sanitising. Must match `topic_for()` in backend/notify.py.
String topicForSymbol(String symbol) =>
    'stock_${symbol.replaceAll(RegExp(r'[^a-zA-Z0-9\-_.~]'), '_')}';

class CompanyLite {
  final String symbol;
  final String name;
  final String sector;
  const CompanyLite({
    required this.symbol,
    required this.name,
    required this.sector,
  });

  factory CompanyLite.fromMap(Map<String, dynamic> m) => CompanyLite(
    symbol: m['symbol'] as String,
    name: m['name'] as String? ?? m['symbol'] as String,
    sector: m['sector'] as String? ?? '',
  );
}

class QuarterResult {
  /// e.g. "Q2FY27"
  final String period;
  final DateTime endDate;
  final double? revenue;
  final double? ebitda;
  final double? pat;
  final double? eps;
  final bool consolidated;

  const QuarterResult({
    required this.period,
    required this.endDate,
    this.revenue,
    this.ebitda,
    this.pat,
    this.eps,
    this.consolidated = true,
  });

  double? get ebitdaMargin =>
      (ebitda != null && revenue != null && revenue! > 0)
      ? ebitda! / revenue! * 100
      : null;

  double? get patMargin => (pat != null && revenue != null && revenue! > 0)
      ? pat! / revenue! * 100
      : null;

  factory QuarterResult.fromMap(Map<String, dynamic> m) => QuarterResult(
    period: m['period'] as String,
    endDate: DateTime.parse(m['endDate'] as String),
    revenue: _d(m['revenue']),
    ebitda: _d(m['ebitda']),
    pat: _d(m['pat']),
    eps: _d(m['eps']),
    consolidated: m['consolidated'] as bool? ?? true,
  );
}

class Credibility {
  final int score; // 0-100
  final int met;
  final int missed;
  final int pending;
  const Credibility({
    this.score = 0,
    this.met = 0,
    this.missed = 0,
    this.pending = 0,
  });

  factory Credibility.fromMap(Map<String, dynamic>? m) => m == null
      ? const Credibility()
      : Credibility(
          score: (m['score'] as num?)?.toInt() ?? 0,
          met: (m['met'] as num?)?.toInt() ?? 0,
          missed: (m['missed'] as num?)?.toInt() ?? 0,
          pending: (m['pending'] as num?)?.toInt() ?? 0,
        );
}

class Company {
  final String symbol;
  final String name;
  final String sector;

  /// Newest first.
  final List<QuarterResult> quarters;
  final Credibility credibility;

  const Company({
    required this.symbol,
    required this.name,
    required this.sector,
    required this.quarters,
    this.credibility = const Credibility(),
  });

  QuarterResult? get latest => quarters.isEmpty ? null : quarters.first;
  QuarterResult? get previousQuarter =>
      quarters.length > 1 ? quarters[1] : null;
  QuarterResult? get yearAgoQuarter => quarters.length > 4 ? quarters[4] : null;

  factory Company.fromMap(Map<String, dynamic> m) {
    final qs =
        (m['quarters'] as List? ?? [])
            .map(
              (e) => QuarterResult.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList()
          ..sort((a, b) => b.endDate.compareTo(a.endDate));
    return Company(
      symbol: m['symbol'] as String,
      name: m['name'] as String? ?? m['symbol'] as String,
      sector: m['sector'] as String? ?? '',
      quarters: qs,
      credibility: Credibility.fromMap(
        (m['credibility'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}

/// Percentage change, or null when not computable.
double? pctChange(double? now, double? before) {
  if (now == null || before == null || before == 0) return null;
  return (now - before) / before.abs() * 100;
}

class QaPair {
  final String q;
  final String a;
  const QaPair(this.q, this.a);
}

class SummaryLang {
  final List<String> highlights;
  final List<String> guidance;
  final List<QaPair> qa;
  final List<String> redFlags;
  const SummaryLang({
    this.highlights = const [],
    this.guidance = const [],
    this.qa = const [],
    this.redFlags = const [],
  });

  bool get isEmpty =>
      highlights.isEmpty && guidance.isEmpty && qa.isEmpty && redFlags.isEmpty;

  factory SummaryLang.fromMap(Map<String, dynamic>? m) => m == null
      ? const SummaryLang()
      : SummaryLang(
          highlights: _strings(m['highlights']),
          guidance: _strings(m['guidance']),
          qa: (m['qa'] as List? ?? [])
              .map(
                (e) => QaPair(
                  (e as Map)['q'] as String? ?? '',
                  e['a'] as String? ?? '',
                ),
              )
              .toList(),
          redFlags: _strings(m['redFlags']),
        );
}

class Concall {
  final String period;
  final DateTime? date;
  final String? transcriptUrl;

  /// positive | neutral | cautious
  final String tone;
  final String? toneChange;

  /// Keyed by language code: en, bn, hi
  final Map<String, SummaryLang> summary;

  const Concall({
    required this.period,
    this.date,
    this.transcriptUrl,
    this.tone = 'neutral',
    this.toneChange,
    this.summary = const {},
  });

  SummaryLang forLang(String lang) {
    final s = summary[lang];
    if (s != null && !s.isEmpty) return s;
    return summary['en'] ?? const SummaryLang();
  }

  factory Concall.fromMap(Map<String, dynamic> m) {
    final raw = (m['summary'] as Map?)?.cast<String, dynamic>() ?? {};
    return Concall(
      period: m['period'] as String,
      date: m['date'] == null ? null : DateTime.tryParse(m['date'] as String),
      transcriptUrl: m['transcriptUrl'] as String?,
      tone: m['tone'] as String? ?? 'neutral',
      toneChange: m['toneChange'] as String?,
      summary: raw.map(
        (k, v) => MapEntry(
          k,
          SummaryLang.fromMap((v as Map?)?.cast<String, dynamic>()),
        ),
      ),
    );
  }
}

enum GuidanceStatus { pending, met, missed }

class GuidanceItem {
  final String statement;
  final String metric;
  final String target;
  final String targetPeriod;
  final String madeIn;
  final GuidanceStatus status;
  final String? actual;

  const GuidanceItem({
    required this.statement,
    required this.metric,
    required this.target,
    required this.targetPeriod,
    required this.madeIn,
    this.status = GuidanceStatus.pending,
    this.actual,
  });

  factory GuidanceItem.fromMap(Map<String, dynamic> m) => GuidanceItem(
    statement: m['statement'] as String? ?? '',
    metric: m['metric'] as String? ?? '',
    target: m['target']?.toString() ?? '',
    targetPeriod: m['targetPeriod'] as String? ?? '',
    madeIn: m['madeIn'] as String? ?? '',
    status: GuidanceStatus.values.firstWhere(
      (s) => s.name == m['status'],
      orElse: () => GuidanceStatus.pending,
    ),
    actual: m['actual']?.toString(),
  );
}

enum EventType { results, concall, investorMeet }

EventType _eventType(String? t) => switch (t) {
  'concall' => EventType.concall,
  'investor_meet' => EventType.investorMeet,
  _ => EventType.results,
};

class CalendarEvent {
  final DateTime date;
  final String symbol;
  final String name;
  final EventType type;

  /// "16:00" or null when not announced.
  final String? time;
  final String? note;

  /// Quarter label for reported results / summarised concalls.
  final String? period;

  /// Concall summary available in the app.
  final bool hasSummary;

  const CalendarEvent({
    required this.date,
    required this.symbol,
    required this.name,
    required this.type,
    this.time,
    this.note,
    this.period,
    this.hasSummary = false,
  });

  factory CalendarEvent.fromMap(Map<String, dynamic> m) => CalendarEvent(
    date: DateTime.parse(m['date'] as String),
    symbol: m['symbol'] as String,
    name: m['name'] as String? ?? m['symbol'] as String,
    type: _eventType(m['type'] as String?),
    time: m['time'] as String?,
    note: m['note'] as String?,
    period: m['period'] as String?,
    hasSummary: m['hasSummary'] as bool? ?? false,
  );
}

class CalendarDay {
  final DateTime date;
  final List<CalendarEvent> events;
  const CalendarDay(this.date, this.events);

  /// Groups events by day, sorted ascending.
  static List<CalendarDay> group(Iterable<CalendarEvent> events) {
    final byDay = <DateTime, List<CalendarEvent>>{};
    for (final e in events) {
      final d = DateTime(e.date.year, e.date.month, e.date.day);
      byDay.putIfAbsent(d, () => []).add(e);
    }
    final days = byDay.entries.map((e) {
      e.value.sort((a, b) => (a.time ?? '99').compareTo(b.time ?? '99'));
      return CalendarDay(e.key, e.value);
    }).toList()..sort((a, b) => a.date.compareTo(b.date));
    return days;
  }
}

class FeedItem {
  final String symbol;
  final String name;
  final String period;
  final double? revenue;
  final double? pat;
  final double? revenueYoY;
  final double? patYoY;
  final DateTime? announcedAt;

  const FeedItem({
    required this.symbol,
    required this.name,
    required this.period,
    this.revenue,
    this.pat,
    this.revenueYoY,
    this.patYoY,
    this.announcedAt,
  });

  factory FeedItem.fromMap(Map<String, dynamic> m) => FeedItem(
    symbol: m['symbol'] as String,
    name: m['name'] as String? ?? m['symbol'] as String,
    period: m['period'] as String? ?? '',
    revenue: _d(m['revenue']),
    pat: _d(m['pat']),
    revenueYoY: _d(m['revenueYoY']),
    patYoY: _d(m['patYoY']),
    announcedAt: m['announcedAt'] == null
        ? null
        : DateTime.tryParse(m['announcedAt'] as String),
  );
}
