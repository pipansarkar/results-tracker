import 'dart:math';

import '../models/models.dart';
import 'repository.dart';

/// Offline SAMPLE data so the app runs before Firebase is configured.
/// Numbers are generated, NOT real company figures. The UI shows a
/// "Sample data" banner whenever this repository is active.
class SeedRepository implements Repository {
  SeedRepository({DateTime? now}) : _now = now ?? DateTime.now() {
    _build();
  }

  final DateTime _now;
  final Map<String, Company> _companies = {};
  final List<FeedItem> _feed = [];
  final List<CalendarEvent> _events = [];
  final Map<String, List<Concall>> _concalls = {};
  final Map<String, List<GuidanceItem>> _guidance = {};

  // symbol, name, sector, base quarterly revenue (₹ Cr), yearly growth, EBITDA margin
  static const _universe = <(String, String, String, double, double, double)>[
    ('TCS', 'Tata Consultancy Services', 'IT Services', 52000, 0.07, 0.27),
    ('INFY', 'Infosys', 'IT Services', 34000, 0.06, 0.24),
    ('HCLTECH', 'HCL Technologies', 'IT Services', 24000, 0.08, 0.22),
    ('WIPRO', 'Wipro', 'IT Services', 22000, 0.02, 0.19),
    (
      'RELIANCE',
      'Reliance Industries',
      'Oil & Gas / Conglomerate',
      210000,
      0.08,
      0.17,
    ),
    ('HDFCBANK', 'HDFC Bank', 'Banking', 82000, 0.12, 0.30),
    ('ICICIBANK', 'ICICI Bank', 'Banking', 48000, 0.14, 0.32),
    ('SBIN', 'State Bank of India', 'Banking', 115000, 0.10, 0.22),
    ('BHARTIARTL', 'Bharti Airtel', 'Telecom', 41000, 0.15, 0.52),
    ('ITC', 'ITC', 'FMCG', 19000, 0.07, 0.36),
    ('LT', 'Larsen & Toubro', 'Capital Goods', 58000, 0.13, 0.11),
    ('MARUTI', 'Maruti Suzuki India', 'Automobiles', 36000, 0.09, 0.12),
    ('M&M', 'Mahindra & Mahindra', 'Automobiles', 30000, 0.16, 0.14),
    ('SUNPHARMA', 'Sun Pharmaceutical', 'Pharma', 13000, 0.10, 0.28),
    ('BEL', 'Bharat Electronics', 'Defence', 5200, 0.18, 0.25),
    ('SUZLON', 'Suzlon Energy', 'Renewable Energy', 2900, 0.45, 0.17),
    ('ASIANPAINT', 'Asian Paints', 'Paints', 8600, 0.01, 0.19),
    ('BAJFINANCE', 'Bajaj Finance', 'NBFC', 17000, 0.24, 0.62),
    ('TITAN', 'Titan Company', 'Consumer Durables', 14000, 0.20, 0.11),
    ('HAL', 'Hindustan Aeronautics', 'Defence', 6500, 0.12, 0.27),
  ];

  @override
  bool get isSample => true;

  static String quarterLabel(DateTime end) {
    final q = switch (end.month) {
      6 => 1,
      9 => 2,
      12 => 3,
      _ => 4,
    };
    final fy = end.month == 3 ? end.year : end.year + 1;
    return 'Q${q}FY${(fy % 100).toString().padLeft(2, '0')}';
  }

  /// Latest quarter end that is at least 30 days in the past.
  DateTime _latestQuarterEnd() {
    var d = DateTime(_now.year, _now.month - 1, 1);
    while (!const [3, 6, 9, 12].contains(d.month)) {
      d = DateTime(d.year, d.month - 1, 1);
    }
    return DateTime(d.year, d.month + 1, 0); // last day of that month
  }

  void _build() {
    final rnd = Random(42);
    final latestEnd = _latestQuarterEnd();
    final today = DateTime(_now.year, _now.month, _now.day);

    for (var i = 0; i < _universe.length; i++) {
      final (symbol, name, sector, base, growth, margin) = _universe[i];
      final quarters = <QuarterResult>[];
      for (var k = 0; k < 12; k++) {
        final end = DateTime(latestEnd.year, latestEnd.month - 3 * k + 1, 0);
        final noise = 1 + (rnd.nextDouble() - 0.5) * 0.06;
        final revenue = base * pow(1 + growth, -k / 4) * noise;
        final m = margin * (1 + (rnd.nextDouble() - 0.5) * 0.12);
        final ebitda = revenue * m;
        // Consistent sample P&L: costs split, then D&A, interest, tax.
        final costs = revenue - ebitda;
        final otherIncome = revenue * 0.015;
        final dep = revenue * 0.03;
        final fin = revenue * 0.01;
        final pbt = ebitda + otherIncome - dep - fin;
        final tax = pbt * 0.25;
        final net = pbt - tax;
        final pat = net * 0.98;
        final eps = double.parse((pat / (base / 40)).toStringAsFixed(2));
        quarters.add(
          QuarterResult(
            period: quarterLabel(end),
            endDate: end,
            revenue: _round(revenue),
            ebitda: _round(ebitda),
            pat: _round(pat),
            eps: eps,
            otherIncome: _round(otherIncome),
            totalIncome: _round(revenue + otherIncome),
            materialCost: _round(costs * 0.45),
            employeeCost: _round(costs * 0.35),
            otherExpenses: _round(costs * 0.20),
            totalExpenses: _round(costs + dep + fin),
            depreciation: _round(dep),
            financeCost: _round(fin),
            exceptional: 0,
            pbt: _round(pbt),
            tax: _round(tax),
            netProfit: _round(net),
            dilutedEps: eps,
            segments: [
              Segment('Domestic', _round(revenue * 0.62)),
              Segment('International', _round(revenue * 0.31)),
              Segment('Others', _round(revenue * 0.07)),
            ],
          ),
        );
      }

      final met = 2 + rnd.nextInt(4);
      final missed = rnd.nextInt(3);
      _companies[symbol] = Company(
        symbol: symbol,
        name: name,
        sector: sector,
        quarters: quarters,
        credibility: Credibility(
          score: (met / (met + missed) * 100).round(),
          met: met,
          missed: missed,
          pending: 2,
        ),
      );

      _concalls[symbol] = [
        for (var k = 0; k < 3; k++)
          _sampleConcall(
            name,
            sector,
            quarters[k],
            k == 0 ? growth : growth * 0.9,
          ),
      ];
      _guidance[symbol] = _sampleGuidance(
        quarters,
        growth,
        margin,
        met,
        missed,
      );

      // Spread events over past and upcoming weeks:
      //  i < 6        reported today, concall tomorrow
      //  i even       reported 3–40 days ago, concall (with summary) 2 days later
      //  otherwise    board meeting in the next two weeks, concall the day after
      final latest = quarters.first;
      final yearAgo = quarters[4];
      final revYoY = pctChange(latest.revenue, yearAgo.revenue);
      final reported =
          'Reported ${latest.period} · Revenue ${revYoY! >= 0 ? '+' : ''}${revYoY.toStringAsFixed(1)}% YoY';
      if (i < 6) {
        _feed.add(
          FeedItem(
            symbol: symbol,
            name: name,
            period: latest.period,
            revenue: latest.revenue,
            pat: latest.pat,
            revenueYoY: revYoY,
            patYoY: pctChange(latest.pat, yearAgo.pat),
            announcedAt: today.add(Duration(hours: 13 + i, minutes: 7 * i)),
          ),
        );
        _addEvent(
          today,
          symbol,
          name,
          EventType.results,
          time: '${13 + i}:00',
          note: reported,
          period: latest.period,
        );
        _addEvent(
          today.add(const Duration(days: 1)),
          symbol,
          name,
          EventType.concall,
          time: '${10 + i % 6}:30',
          note: 'Earnings call for ${latest.period}',
        );
      } else if (i.isEven) {
        final day = today.subtract(Duration(days: 3 + (i * 3) % 38));
        _addEvent(
          day,
          symbol,
          name,
          EventType.results,
          time: '15:30',
          note: reported,
          period: latest.period,
        );
        _addEvent(
          day.add(const Duration(days: 2)),
          symbol,
          name,
          EventType.concall,
          time: '16:00',
          note: '${latest.period} earnings call · summary ready',
          period: latest.period,
          hasSummary: true,
        );
      } else {
        final day = today.add(Duration(days: 1 + (i - 6) % 13));
        _addEvent(
          day,
          symbol,
          name,
          EventType.results,
          note: 'Board meeting: financial results',
        );
        _addEvent(
          day.add(const Duration(days: 1)),
          symbol,
          name,
          EventType.concall,
          time: '16:00',
          note: 'Earnings call for ${latest.period}',
        );
      }
      // Investor conferences, past and upcoming.
      if (i % 3 == 0) {
        _addEvent(
          today.add(Duration(days: i % 2 == 0 ? 6 + i % 9 : -(5 + i % 20))),
          symbol,
          name,
          EventType.investorMeet,
          time: '11:00',
          note: 'Investor conference',
        );
      }
    }
  }

  void _addEvent(
    DateTime day,
    String symbol,
    String name,
    EventType type, {
    String? time,
    String? note,
    String? period,
    bool hasSummary = false,
  }) => _events.add(
    CalendarEvent(
      date: day,
      symbol: symbol,
      name: name,
      type: type,
      time: time,
      note: note,
      period: period,
      hasSummary: hasSummary,
    ),
  );

  static double _round(double v) => double.parse(v.toStringAsFixed(1));

  Concall _sampleConcall(
    String name,
    String sector,
    QuarterResult q,
    double growth,
  ) {
    final g = (growth * 100).round();
    final tone = growth > 0.12
        ? 'positive'
        : (growth < 0.04 ? 'cautious' : 'neutral');
    return Concall(
      period: q.period,
      date: q.endDate.add(const Duration(days: 25)),
      transcriptUrl:
          'https://www.nseindia.com/companies-listing/corporate-filings-announcements',
      tone: tone,
      toneChange: tone == 'cautious'
          ? 'More cautious than last quarter'
          : 'Similar to last quarter',
      summary: {
        'en': SummaryLang(
          highlights: [
            '[Sample] $name reported revenue of ₹${q.revenue!.toStringAsFixed(0)} Cr for ${q.period}.',
            '[Sample] EBITDA margin at ${q.ebitdaMargin!.toStringAsFixed(1)}%; management cited operating leverage.',
            '[Sample] Demand in the $sector segment described as "steady" with pockets of strength.',
          ],
          guidance: [
            '[Sample] Revenue growth of ~$g% expected for the full year.',
            '[Sample] EBITDA margin to stay in a ${(q.ebitdaMargin! - 1).toStringAsFixed(0)}–${(q.ebitdaMargin! + 1).toStringAsFixed(0)}% band.',
          ],
          qa: const [
            QaPair(
              '[Sample] What is driving the margin change?',
              'Better pricing and lower input costs, partly offset by wage hikes.',
            ),
            QaPair(
              '[Sample] Any update on capex plans?',
              'Capex guidance unchanged; new capacity expected to go live next year.',
            ),
          ],
          redFlags: tone == 'cautious'
              ? const [
                  '[Sample] Receivables up faster than revenue.',
                  '[Sample] Guidance language softer than last quarter.',
                ]
              : const [],
        ),
        'bn': SummaryLang(
          highlights: [
            '[নমুনা] $name ${q.period}-এ ₹${q.revenue!.toStringAsFixed(0)} কোটি আয় করেছে।',
            '[নমুনা] EBITDA মার্জিন ${q.ebitdaMargin!.toStringAsFixed(1)}%।',
          ],
          guidance: ['[নমুনা] পুরো বছরে প্রায় $g% আয় বৃদ্ধির আশা।'],
          qa: const [
            QaPair(
              '[নমুনা] মার্জিন বদলের কারণ কী?',
              'ভালো দাম এবং কম কাঁচামালের খরচ।',
            ),
          ],
        ),
        'hi': SummaryLang(
          highlights: [
            '[नमूना] $name ने ${q.period} में ₹${q.revenue!.toStringAsFixed(0)} करोड़ का राजस्व दर्ज किया।',
            '[नमूना] EBITDA मार्जिन ${q.ebitdaMargin!.toStringAsFixed(1)}% रहा।',
          ],
          guidance: ['[नमूना] पूरे साल में लगभग $g% राजस्व वृद्धि की उम्मीद।'],
          qa: const [
            QaPair(
              '[नमूना] मार्जिन में बदलाव का कारण?',
              'बेहतर कीमतें और कम कच्चे माल की लागत।',
            ),
          ],
        ),
      },
    );
  }

  List<GuidanceItem> _sampleGuidance(
    List<QuarterResult> qs,
    double growth,
    double margin,
    int met,
    int missed,
  ) {
    final items = <GuidanceItem>[];
    for (var k = 0; k < met; k++) {
      items.add(
        GuidanceItem(
          statement:
              '[Sample] EBITDA margin of at least ${(margin * 100 - 2).toStringAsFixed(0)}%',
          metric: 'EBITDA margin',
          target: '≥ ${(margin * 100 - 2).toStringAsFixed(0)}%',
          targetPeriod: qs[k + 1].period,
          madeIn: qs[k + 3].period,
          status: GuidanceStatus.met,
          actual: '${qs[k + 1].ebitdaMargin!.toStringAsFixed(1)}%',
        ),
      );
    }
    for (var k = 0; k < missed; k++) {
      items.add(
        GuidanceItem(
          statement:
              '[Sample] Revenue growth of ${(growth * 100 + 5).round()}% YoY',
          metric: 'Revenue growth',
          target: '${(growth * 100 + 5).round()}%',
          targetPeriod: qs[k + 2].period,
          madeIn: qs[k + 5].period,
          status: GuidanceStatus.missed,
          actual: '${(growth * 100).round()}%',
        ),
      );
    }
    items.insertAll(0, [
      GuidanceItem(
        statement:
            '[Sample] Full-year revenue growth around ${(growth * 100).round()}%',
        metric: 'Revenue growth',
        target: '${(growth * 100).round()}%',
        targetPeriod: 'FY${qs.first.period.substring(4)}',
        madeIn: qs.first.period,
      ),
      GuidanceItem(
        statement: '[Sample] Margins to improve by 50–100 bps next quarter',
        metric: 'EBITDA margin',
        target: '+50–100 bps',
        targetPeriod: 'next quarter',
        madeIn: qs.first.period,
      ),
    ]);
    return items;
  }

  @override
  Future<List<CompanyLite>> allCompanies() async =>
      _companies.values
          .map(
            (c) =>
                CompanyLite(symbol: c.symbol, name: c.name, sector: c.sector),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  @override
  Stream<List<FeedItem>> todayFeed() => Stream.value(
    [..._feed]..sort((a, b) => b.announcedAt!.compareTo(a.announcedAt!)),
  );

  @override
  Future<List<CalendarDay>> calendar(DateTime from, DateTime to) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day, 23, 59);
    return CalendarDay.group(
      _events.where((e) => !e.date.isBefore(start) && !e.date.isAfter(end)),
    );
  }

  @override
  Stream<Company?> company(String symbol) => Stream.value(_companies[symbol]);

  @override
  Future<List<Concall>> concalls(String symbol) async =>
      _concalls[symbol] ?? [];

  @override
  Future<List<GuidanceItem>> guidance(String symbol) async =>
      _guidance[symbol] ?? [];

  @override
  Future<List<NewsItem>> filings(String symbol) async {
    final c = _companies[symbol];
    if (c == null) return [];
    final q = c.latest!;
    final d = q.endDate.add(const Duration(days: 20));
    return [
      NewsItem(
        date: d.add(const Duration(days: 3)),
        title: 'Analysts/Institutional Investor Meet/Con. Call Updates',
        text:
            '[Sample] Transcript of the ${q.period} earnings conference call.',
        source: 'NSE',
      ),
      NewsItem(
        date: d,
        title: 'Outcome of Board Meeting',
        text:
            '[Sample] Board approved unaudited financial results for ${q.period}.',
        source: 'NSE',
      ),
      NewsItem(
        date: d.subtract(const Duration(days: 9)),
        title: 'Board Meeting Intimation',
        text: '[Sample] Board meeting to consider ${q.period} results.',
        source: 'NSE',
      ),
    ];
  }
}
