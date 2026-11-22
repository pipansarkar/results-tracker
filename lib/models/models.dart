// Data models. Field names match the Firestore documents written by the
// Python pipeline in backend/ (see backend/firestore_io.py).
// All money values are in ₹ crore.

double? _d(dynamic v) => v == null ? null : (v as num).toDouble();
Map<String, double> _numMap(dynamic v) => v == null
    ? const {}
    : {
        for (final e in (v as Map).entries)
          if (e.value is num) e.key as String: (e.value as num).toDouble(),
      };

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
  final bool nifty500;
  const CompanyLite({
    required this.symbol,
    required this.name,
    required this.sector,
    this.nifty500 = false,
  });

  factory CompanyLite.fromMap(Map<String, dynamic> m) => CompanyLite(
    symbol: m['symbol'] as String,
    name: m['name'] as String? ?? m['symbol'] as String,
    sector: m['sector'] as String? ?? '',
    nifty500: m['n500'] as bool? ?? false,
  );
}

class Segment {
  final String name;
  final double revenue;
  const Segment(this.name, this.revenue);
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

  // Detailed P&L (₹ crore); null when the filing doesn't report the line.
  final double? otherIncome;
  final double? totalIncome;
  final double? materialCost;
  final double? employeeCost;
  final double? otherExpenses;
  final double? totalExpenses;
  final double? depreciation;
  final double? financeCost;
  final double? exceptional;
  final double? pbt;
  final double? tax;

  /// Profit incl. minority interest (pat is attributable to shareholders).
  final double? netProfit;
  final double? dilutedEps;
  final List<Segment> segments;

  /// When the result was filed, and the share price move it triggered (%).
  final DateTime? filedAt;
  final double? reaction;

  /// Balance sheet lines (₹ Cr) and year-to-date cash flow (₹ Cr; 'months'
  /// = 6 or 12). Filed with half-year and full-year results only.
  final Map<String, double> bs;
  final Map<String, double> cf;

  const QuarterResult({
    required this.period,
    required this.endDate,
    this.revenue,
    this.ebitda,
    this.pat,
    this.eps,
    this.consolidated = true,
    this.otherIncome,
    this.totalIncome,
    this.materialCost,
    this.employeeCost,
    this.otherExpenses,
    this.totalExpenses,
    this.depreciation,
    this.financeCost,
    this.exceptional,
    this.pbt,
    this.tax,
    this.netProfit,
    this.dilutedEps,
    this.segments = const [],
    this.filedAt,
    this.reaction,
    this.bs = const {},
    this.cf = const {},
  });

  double? _ofRevenue(double? v) =>
      (v != null && revenue != null && revenue! > 0)
      ? v / revenue! * 100
      : null;

  double? get ebitdaMargin => _ofRevenue(ebitda);
  double? get patMargin => _ofRevenue(pat);
  double? get pbtMargin => _ofRevenue(pbt);
  double? get taxRate =>
      (tax != null && pbt != null && pbt! > 0) ? tax! / pbt! * 100 : null;

  factory QuarterResult.fromMap(Map<String, dynamic> m) => QuarterResult(
    period: m['period'] as String,
    endDate: DateTime.parse(m['endDate'] as String),
    revenue: _d(m['revenue']),
    ebitda: _d(m['ebitda']),
    pat: _d(m['pat']),
    eps: _d(m['eps']),
    consolidated: m['consolidated'] as bool? ?? true,
    otherIncome: _d(m['otherIncome']),
    totalIncome: _d(m['totalIncome']),
    materialCost: _d(m['materialCost']),
    employeeCost: _d(m['employeeCost']),
    otherExpenses: _d(m['otherExpenses']),
    totalExpenses: _d(m['totalExpenses']),
    depreciation: _d(m['depreciation']),
    financeCost: _d(m['financeCost']),
    exceptional: _d(m['exceptional']),
    pbt: _d(m['pbt']),
    tax: _d(m['tax']),
    netProfit: _d(m['netProfit']),
    dilutedEps: _d(m['dilutedEps']),
    filedAt: m['filedAt'] == null
        ? null
        : DateTime.tryParse(m['filedAt'] as String),
    reaction: _d(m['reaction']),
    bs: _numMap(m['bs']),
    cf: _numMap(m['cf']),
    segments: [
      for (final e in (m['segments'] as List? ?? []))
        if ((e as Map)['revenue'] != null)
          Segment(e['name'] as String? ?? '', (e['revenue'] as num).toDouble()),
    ],
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

  /// Shareholding pattern by quarter, newest first.
  final List<HoldingPoint> holding;

  const Company({
    required this.symbol,
    required this.name,
    required this.sector,
    required this.quarters,
    this.credibility = const Credibility(),
    this.holding = const [],
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
      holding: [
        for (final h in (m['holding'] as List? ?? []))
          HoldingPoint.fromMap(Map<String, dynamic>.from(h as Map)),
      ],
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

  /// What changed vs the previous call (AI) and the rule-based guidance diff.
  final ConcallChanges? changes;
  final List<GuidanceChange> guidanceDiff;
  final String? previousPeriod;

  const Concall({
    required this.period,
    this.date,
    this.transcriptUrl,
    this.tone = 'neutral',
    this.toneChange,
    this.summary = const {},
    this.changes,
    this.guidanceDiff = const [],
    this.previousPeriod,
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
      changes: m['changes'] == null
          ? null
          : ConcallChanges.fromMap(
              Map<String, dynamic>.from(m['changes'] as Map),
            ),
      guidanceDiff: [
        for (final g in (m['guidanceDiff'] as List? ?? []))
          GuidanceChange.fromMap(Map<String, dynamic>.from(g as Map)),
      ],
      previousPeriod: m['previousPeriod'] as String?,
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

enum EventType { results, concall, investorMeet, corpAction }

EventType _eventType(String? t) => switch (t) {
  'concall' => EventType.concall,
  'investor_meet' => EventType.investorMeet,
  'corp_action' => EventType.corpAction,
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
  final double? reaction;

  const FeedItem({
    required this.symbol,
    required this.name,
    required this.period,
    this.revenue,
    this.pat,
    this.revenueYoY,
    this.patYoY,
    this.announcedAt,
    this.reaction,
  });

  factory FeedItem.fromMap(Map<String, dynamic> m) => FeedItem(
    symbol: m['symbol'] as String,
    name: m['name'] as String? ?? m['symbol'] as String,
    period: m['period'] as String? ?? '',
    revenue: _d(m['revenue']),
    pat: _d(m['pat']),
    revenueYoY: _d(m['revenueYoY']),
    patYoY: _d(m['patYoY']),
    reaction: _d(m['reaction']),
    announcedAt: m['announcedAt'] == null
        ? null
        : DateTime.tryParse(m['announcedAt'] as String),
  );
}

/// A company announcement filed on NSE, or a media headline.
class NewsItem {
  final DateTime date;
  final String title;
  final String? text;
  final String? url;

  /// "NSE" for exchange filings, otherwise the publisher.
  final String source;

  /// Red-flag label (e.g. "Auditor resigned") and severity, for filings.
  final String? flag;
  final String? severity;

  const NewsItem({
    required this.date,
    required this.title,
    this.text,
    this.url,
    required this.source,
    this.flag,
    this.severity,
  });

  factory NewsItem.fromMap(Map<String, dynamic> m) => NewsItem(
    date: DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime(2000),
    title: m['title'] as String? ?? '',
    text: m['text'] as String?,
    url: m['url'] as String?,
    source: 'NSE',
    flag: m['flag'] as String?,
    severity: m['severity'] as String?,
  );
}

/// Valuation and quality ratios for one stock (screener/{n} docs).
/// TTM = trailing twelve months. Null when not meaningful (e.g. P/E for a
/// loss-making company, debt ratios for banks).
class StockMetrics {
  final String symbol;
  final String? period;
  final double? price;
  final double? marketCap; // ₹ Cr
  final double? pe;
  final double? peg;
  final double? pb;
  final double? roe;
  final double? roce;
  final double? debtEquity;
  final double? evEbitda;
  final double? bookValue;
  final double? epsTtm;
  final double? revenueTtm;
  final double? profitTtm;
  final double? revGrowth; // latest quarter YoY %
  final double? profitGrowth;
  final double? revGrowthTtm;
  final double? profitGrowthTtm;
  final double? ebitdaMargin; // TTM %
  final double? netMargin;
  final bool isBank;

  const StockMetrics({
    required this.symbol,
    this.period,
    this.price,
    this.marketCap,
    this.pe,
    this.peg,
    this.pb,
    this.roe,
    this.roce,
    this.debtEquity,
    this.evEbitda,
    this.bookValue,
    this.epsTtm,
    this.revenueTtm,
    this.profitTtm,
    this.revGrowth,
    this.profitGrowth,
    this.revGrowthTtm,
    this.profitGrowthTtm,
    this.ebitdaMargin,
    this.netMargin,
    this.isBank = false,
  });

  factory StockMetrics.fromMap(Map<String, dynamic> m) => StockMetrics(
    symbol: m['s'] as String,
    period: m['q'] as String?,
    price: _d(m['p']),
    marketCap: _d(m['mc']),
    pe: _d(m['pe']),
    peg: _d(m['peg']),
    pb: _d(m['pb']),
    roe: _d(m['roe']),
    roce: _d(m['roce']),
    debtEquity: _d(m['de']),
    evEbitda: _d(m['ev']),
    bookValue: _d(m['bv']),
    epsTtm: _d(m['eps']),
    revenueTtm: _d(m['rev']),
    profitTtm: _d(m['pat']),
    revGrowth: _d(m['rg']),
    profitGrowth: _d(m['pg']),
    revGrowthTtm: _d(m['rgt']),
    profitGrowthTtm: _d(m['pgt']),
    ebitdaMargin: _d(m['ebm']),
    netMargin: _d(m['npm']),
    isBank: m['bank'] as bool? ?? false,
  );
}

/// One metric that can be shown, filtered, sorted and compared.
class MetricDef {
  final String key;
  final String label;
  final String short;
  final double? Function(StockMetrics) get;

  /// '%', 'x', '₹', 'Cr'
  final String unit;

  /// For "best" highlighting in Compare: true if higher is better.
  final bool higherIsBetter;
  final String help;

  const MetricDef(
    this.key,
    this.label,
    this.short,
    this.get,
    this.unit, {
    this.higherIsBetter = true,
    this.help = '',
  });
}

final List<MetricDef> metricDefs = [
  MetricDef(
    'mc',
    'Market cap',
    'M.Cap',
    (m) => m.marketCap,
    'Cr',
    help: 'Share price × shares outstanding.',
  ),
  MetricDef(
    'p',
    'Price',
    'Price',
    (m) => m.price,
    '₹',
    help: 'Last NSE closing price.',
  ),
  MetricDef(
    'pe',
    'P/E',
    'P/E',
    (m) => m.pe,
    'x',
    higherIsBetter: false,
    help: 'Price ÷ earnings per share over the last 12 months.',
  ),
  MetricDef(
    'peg',
    'PEG',
    'PEG',
    (m) => m.peg,
    'x',
    higherIsBetter: false,
    help: 'P/E ÷ yearly EPS growth %. Below 1 can mean growth is cheap.',
  ),
  MetricDef(
    'pb',
    'P/B',
    'P/B',
    (m) => m.pb,
    'x',
    higherIsBetter: false,
    help: 'Market cap ÷ shareholders\' equity (book value).',
  ),
  MetricDef(
    'ev',
    'EV/EBITDA',
    'EV/EBITDA',
    (m) => m.evEbitda,
    'x',
    higherIsBetter: false,
    help: '(Market cap + debt − cash) ÷ EBITDA over 12 months.',
  ),
  MetricDef(
    'roe',
    'ROE',
    'ROE',
    (m) => m.roe,
    '%',
    help: 'Profit over 12 months ÷ shareholders\' equity.',
  ),
  MetricDef(
    'roce',
    'ROCE',
    'ROCE',
    (m) => m.roce,
    '%',
    help: 'Operating profit (EBIT) ÷ capital employed (equity + debt).',
  ),
  MetricDef(
    'de',
    'Debt / equity',
    'D/E',
    (m) => m.debtEquity,
    'x',
    higherIsBetter: false,
    help: 'Borrowings ÷ shareholders\' equity.',
  ),
  MetricDef(
    'rg',
    'Revenue growth (qtr YoY)',
    'Rev gr.',
    (m) => m.revGrowth,
    '%',
    help: 'Latest quarter revenue vs same quarter last year.',
  ),
  MetricDef(
    'pg',
    'Profit growth (qtr YoY)',
    'Profit gr.',
    (m) => m.profitGrowth,
    '%',
    help: 'Latest quarter profit vs same quarter last year.',
  ),
  MetricDef(
    'rgt',
    'Revenue growth (TTM)',
    'Rev gr. TTM',
    (m) => m.revGrowthTtm,
    '%',
    help: 'Last 12 months revenue vs the 12 months before.',
  ),
  MetricDef(
    'pgt',
    'Profit growth (TTM)',
    'Profit gr. TTM',
    (m) => m.profitGrowthTtm,
    '%',
    help: 'Last 12 months profit vs the 12 months before.',
  ),
  MetricDef(
    'ebm',
    'EBITDA margin (TTM)',
    'EBITDA %',
    (m) => m.ebitdaMargin,
    '%',
    help: 'EBITDA ÷ revenue over the last 12 months.',
  ),
  MetricDef(
    'npm',
    'Net margin (TTM)',
    'Net %',
    (m) => m.netMargin,
    '%',
    help: 'Profit ÷ revenue over the last 12 months.',
  ),
  MetricDef(
    'eps',
    'EPS (TTM)',
    'EPS',
    (m) => m.epsTtm,
    '₹',
    help: 'Earnings per share over the last 12 months.',
  ),
  MetricDef(
    'bv',
    'Book value / share',
    'BV',
    (m) => m.bookValue,
    '₹',
    help: 'Shareholders\' equity ÷ shares outstanding.',
  ),
  MetricDef(
    'rev',
    'Revenue (TTM)',
    'Revenue',
    (m) => m.revenueTtm,
    'Cr',
    help: 'Revenue over the last 12 months.',
  ),
  MetricDef(
    'pat',
    'Net profit (TTM)',
    'Profit',
    (m) => m.profitTtm,
    'Cr',
    help: 'Profit to shareholders over the last 12 months.',
  ),
];

MetricDef metricDef(String key) => metricDefs.firstWhere((d) => d.key == key);

class HoldingPoint {
  final DateTime date;
  final double? promoter, fii, dii, mf, insurance, retail, others, pledge;
  const HoldingPoint({
    required this.date,
    this.promoter,
    this.fii,
    this.dii,
    this.mf,
    this.insurance,
    this.retail,
    this.others,
    this.pledge,
  });

  factory HoldingPoint.fromMap(Map<String, dynamic> m) {
    // Guard against percentages stored ×100 by an older pipeline version.
    final scale = (_d(m['promoter']) ?? 0) > 100 || (_d(m['public']) ?? 0) > 100
        ? 100.0
        : 1.0;
    double? p(String k) => _d(m[k]) == null ? null : _d(m[k])! / scale;
    return HoldingPoint(
      date: DateTime.parse(m['date'] as String),
      promoter: p('promoter'),
      fii: p('fii'),
      dii: p('dii'),
      mf: p('mf'),
      insurance: p('insurance'),
      retail: p('retail'),
      others: p('others'),
      pledge: _d(m['pledge']),
    );
  }

  String get label {
    const m = ['Mar', 'Jun', 'Sep', 'Dec'];
    final i = (date.month / 3).ceil() - 1;
    return "${m[i.clamp(0, 3)]} '${(date.year % 100).toString().padLeft(2, '0')}";
  }
}

/// A deal, stake change, ownership shift or red flag for one company.
class ActivityItem {
  final DateTime date;

  /// bulk | block | sast | insider | holding | flag
  final String kind;
  final String? who;
  final String? side; // buy | sell
  final double? qty, price, valueCr, holdingAfter;
  final bool promoter;
  final bool intraday;
  final String? text; // holding change / flag label
  final String? severity; // high | medium | low
  final String? detail;
  final String? url;

  const ActivityItem({
    required this.date,
    required this.kind,
    this.who,
    this.side,
    this.qty,
    this.price,
    this.valueCr,
    this.holdingAfter,
    this.promoter = false,
    this.intraday = false,
    this.text,
    this.severity,
    this.detail,
    this.url,
  });

  bool get isDeal => const {'bulk', 'block', 'sast', 'insider'}.contains(kind);

  factory ActivityItem.fromMap(Map<String, dynamic> m) => ActivityItem(
    date: DateTime.tryParse(m['date'] as String? ?? '') ?? DateTime(2000),
    kind: m['kind'] as String? ?? 'flag',
    who: m['who'] as String?,
    side: m['side'] as String?,
    qty: _d(m['qty']),
    price: _d(m['price']),
    valueCr: _d(m['valueCr']),
    holdingAfter: _d(m['holdingAfter']),
    promoter: m['promoter'] as bool? ?? false,
    intraday: m['intraday'] as bool? ?? false,
    text: m['text'] as String?,
    severity: m['severity'] as String?,
    detail: m['detail'] as String?,
    url: m['url'] as String?,
  );
}

/// A market-wide deal (deals/latest).
class MarketDeal {
  final String symbol;
  final String name;
  final ActivityItem item;
  const MarketDeal(this.symbol, this.name, this.item);

  factory MarketDeal.fromMap(Map<String, dynamic> m) => MarketDeal(
    m['symbol'] as String,
    m['name'] as String? ?? m['symbol'] as String,
    ActivityItem.fromMap(m),
  );
}

class ConcallChanges {
  final String summary;
  final List<String> newTopics, droppedTopics, guidanceShifts;
  final String? toneShift, bn, hi;
  const ConcallChanges({
    required this.summary,
    this.newTopics = const [],
    this.droppedTopics = const [],
    this.guidanceShifts = const [],
    this.toneShift,
    this.bn,
    this.hi,
  });

  String summaryFor(String lang) =>
      (lang == 'bn' ? bn : (lang == 'hi' ? hi : null)) ?? summary;

  factory ConcallChanges.fromMap(Map<String, dynamic> m) => ConcallChanges(
    summary: m['summary'] as String? ?? '',
    newTopics: _strings(m['newTopics']),
    droppedTopics: _strings(m['droppedTopics']),
    guidanceShifts: _strings(m['guidanceShifts']),
    toneShift: m['toneShift'] as String?,
    bn: m['bn'] as String?,
    hi: m['hi'] as String?,
  );
}

class GuidanceChange {
  final String label, targetPeriod, direction;
  final String? before, now, statement;
  const GuidanceChange({
    required this.label,
    required this.targetPeriod,
    required this.direction,
    this.before,
    this.now,
    this.statement,
  });

  factory GuidanceChange.fromMap(Map<String, dynamic> m) => GuidanceChange(
    label: m['label'] as String? ?? '',
    targetPeriod: m['targetPeriod'] as String? ?? '',
    direction: m['direction'] as String? ?? 'reiterated',
    before: m['before'] as String?,
    now: m['now'] as String?,
    statement: m['statement'] as String?,
  );
}

/// Results-season scoreboard (meta/season).
class Season {
  final String season;
  final int reported, total;
  final double? revGrewPct, profitGrewPct, medianRevGrowth, medianProfitGrowth;
  final List<Map<String, dynamic>> sectors,
      topProfit,
      worstProfit,
      bestReaction,
      worstReaction;
  const Season({
    required this.season,
    required this.reported,
    required this.total,
    this.revGrewPct,
    this.profitGrewPct,
    this.medianRevGrowth,
    this.medianProfitGrowth,
    this.sectors = const [],
    this.topProfit = const [],
    this.worstProfit = const [],
    this.bestReaction = const [],
    this.worstReaction = const [],
  });

  static List<Map<String, dynamic>> _list(dynamic v) => [
    for (final e in (v as List? ?? [])) Map<String, dynamic>.from(e as Map),
  ];

  factory Season.fromMap(Map<String, dynamic> m) => Season(
    season: m['season'] as String? ?? '',
    reported: (m['reported'] as num?)?.toInt() ?? 0,
    total: (m['total'] as num?)?.toInt() ?? 0,
    revGrewPct: _d(m['revGrewPct']),
    profitGrewPct: _d(m['profitGrewPct']),
    medianRevGrowth: _d(m['medianRevGrowth']),
    medianProfitGrowth: _d(m['medianProfitGrowth']),
    sectors: _list(m['sectors']),
    topProfit: _list(m['topProfit']),
    worstProfit: _list(m['worstProfit']),
    bestReaction: _list(m['bestReaction']),
    worstReaction: _list(m['worstReaction']),
  );
}
