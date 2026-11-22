import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/models.dart';

/// Media headlines from the free Google News RSS feed, fetched on the
/// device (no key, no backend cost). Results are cached for 30 minutes.
class MediaNews {
  MediaNews({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  final _cache = <String, (DateTime, List<NewsItem>)>{};

  Future<List<NewsItem>> forCompany(String name, String symbol) async {
    final cached = _cache[symbol];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 30)) {
      return cached.$2;
    }
    final clean = name
        .replaceAll(RegExp(r'\b(limited|ltd\.?)\b', caseSensitive: false), '')
        .trim();
    final q = '"$clean" share OR stock OR results';
    final uri = Uri.https('news.google.com', '/rss/search', {
      'q': q,
      'hl': 'en-IN',
      'gl': 'IN',
      'ceid': 'IN:en',
    });
    final res = await _client.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw Exception('News unavailable (HTTP ${res.statusCode})');
    }
    final items = parseRss(res.body);
    _cache[symbol] = (DateTime.now(), items);
    return items;
  }

  /// Parses a Google News RSS document. Titles look like
  /// "Headline - Publisher"; the publisher is split off.
  static List<NewsItem> parseRss(String body, {int limit = 30}) {
    final doc = XmlDocument.parse(body);
    final out = <NewsItem>[];
    for (final item in doc.findAllElements('item').take(limit)) {
      String text(String tag) =>
          item.findElements(tag).firstOrNull?.innerText.trim() ?? '';
      var title = text('title');
      var source = text('source');
      if (source.isNotEmpty && title.endsWith(' - $source')) {
        title = title.substring(0, title.length - source.length - 3);
      }
      out.add(
        NewsItem(
          date: _parseRfc822(text('pubDate')) ?? DateTime(2000),
          title: title,
          url: text('link'),
          source: source.isEmpty ? 'News' : source,
        ),
      );
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  static const _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };

  /// "Sun, 22 Nov 2026 04:10:00 GMT" -> local DateTime.
  static DateTime? _parseRfc822(String s) {
    final m = RegExp(
      r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(s);
    if (m == null) return null;
    final month = _months[m.group(2)];
    if (month == null) return null;
    return DateTime.utc(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    ).toLocal();
  }
}
