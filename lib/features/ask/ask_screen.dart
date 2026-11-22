import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/material.dart';
import '../../core/i18n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/repository.dart' show dateId;
import '../../widgets/common.dart';

const _suggestions = [
  'Summarise the last 4 quarters',
  'What did management say about margins?',
  'Is management delivering on its guidance?',
  'Any red flags I should know about?',
  'How has shareholding changed?',
  'How does it compare with peers on valuation?',
];

/// Ask questions about one company. Answers come only from the app's own
/// data for that company (results, concall summaries, guidance, ownership,
/// filings), via Gemini through Firebase AI Logic (free tier, no key in app).
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key, required this.symbol});
  final String symbol;

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _Msg {
  _Msg(this.fromUser, this.text, {this.error = false});
  final bool fromUser;
  String text;
  final bool error;
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<String> _context() async {
    final repo = ref.read(repositoryProvider);
    final c = await ref.read(companyProvider(widget.symbol).future);
    final calls = await repo.concalls(widget.symbol);
    final guidance = await repo.guidance(widget.symbol);
    final filings = await repo.filings(widget.symbol);
    final activity = await repo.activity(widget.symbol);
    final m = ref.read(metricsProvider(widget.symbol));
    final b = StringBuffer();
    if (c != null) {
      b.writeln('COMPANY: ${c.name} (${c.symbol}), sector ${c.sector}.');
      b.writeln('QUARTERLY RESULTS (₹ crore, newest first):');
      for (final q in c.quarters.take(12)) {
        b.writeln(
          '${q.period}: revenue ${q.revenue}, EBITDA ${q.ebitda} '
          '(margin ${q.ebitdaMargin?.toStringAsFixed(1)}%), PAT ${q.pat}, EPS ${q.eps}'
          '${q.reaction != null ? ', share price reaction ${q.reaction}%' : ''}',
        );
      }
      for (final q in c.quarters.where((q) => q.bs.isNotEmpty).take(2)) {
        b.writeln('BALANCE SHEET ${q.period}: ${q.bs}');
      }
      for (final q in c.quarters.where((q) => q.cf.isNotEmpty).take(2)) {
        b.writeln('CASH FLOW YTD ${q.period}: ${q.cf}');
      }
      if (c.holding.isNotEmpty) {
        b.writeln('SHAREHOLDING % (newest first):');
        for (final h in c.holding.take(4)) {
          b.writeln(
            '${h.label}: promoter ${h.promoter}, FII ${h.fii}, DII ${h.dii}, '
            'MF ${h.mf}, retail ${h.retail}, pledge ${h.pledge}',
          );
        }
      }
    }
    if (m != null) {
      b.writeln(
        'RATIOS: price ₹${m.price}, market cap ₹${m.marketCap} Cr, P/E ${m.pe}, '
        'PEG ${m.peg}, P/B ${m.pb}, ROE ${m.roe}%, ROCE ${m.roce}%, D/E ${m.debtEquity}, '
        'EV/EBITDA ${m.evEbitda}.',
      );
    }
    for (final call in calls.take(4)) {
      final en = call.forLang('en');
      b.writeln('CONCALL ${call.period} (tone ${call.tone}):');
      b.writeln(' Highlights: ${en.highlights.join(' | ')}');
      b.writeln(' Guidance: ${en.guidance.join(' | ')}');
      b.writeln(' Q&A: ${en.qa.map((x) => '${x.q} -> ${x.a}').join(' | ')}');
      if (en.redFlags.isNotEmpty) {
        b.writeln(' Red flags: ${en.redFlags.join(' | ')}');
      }
      if (call.changes != null) {
        b.writeln(' Changes vs previous call: ${call.changes!.summary}');
      }
    }
    if (guidance.isNotEmpty) {
      b.writeln('GUIDANCE TRACKER:');
      for (final g in guidance.take(20)) {
        b.writeln(
          '- ${g.statement} (made ${g.madeIn}, for ${g.targetPeriod}): '
          '${g.status.name}${g.actual != null ? ', actual ${g.actual}' : ''}',
        );
      }
    }
    for (final a in activity.take(15)) {
      b.writeln(
        'ACTIVITY ${dateId(a.date)}: ${a.kind} ${a.side ?? ''} ${a.who ?? ''} '
        '${a.text ?? ''} ${a.valueCr != null ? '₹${a.valueCr} Cr' : ''}',
      );
    }
    for (final f in filings.take(15)) {
      b.writeln(
        'FILING ${dateId(f.date)}: ${f.title}${f.flag != null ? ' [RED FLAG: ${f.flag}]' : ''}',
      );
    }
    final text = b.toString();
    return text.length > 60000 ? text.substring(0, 60000) : text;
  }

  Future<String> _model() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('meta')
          .doc('config')
          .get();
      return doc.data()?['aiModel'] as String? ?? 'gemini-3.8-flash';
    } catch (_) {
      return 'gemini-3.8-flash';
    }
  }

  Future<void> _ask(String q) async {
    q = q.trim();
    if (q.isEmpty || _busy) return;
    _ctrl.clear();
    setState(() {
      _msgs.add(_Msg(true, q));
      _busy = true;
    });
    _scrollDown();
    if (!ref.read(firebaseEnabledProvider)) {
      setState(() {
        _msgs.add(
          _Msg(
            false,
            'Ask AI works once the app is connected to Firebase.',
            error: true,
          ),
        );
        _busy = false;
      });
      return;
    }
    final lang = languageNames[ref.read(languageProvider)] ?? 'English';
    try {
      final data = await _context();
      final model = FirebaseAI.googleAI().generativeModel(
        model: await _model(),
        systemInstruction: Content.system(
          'You answer questions about one Indian listed company for retail investors. '
          'Use ONLY the data provided; if it does not contain the answer, say so. '
          'Quote periods (e.g. Q2FY27) and numbers. Be concise: short paragraphs or bullets. '
          'Never give buy/sell/hold advice or price targets. Answer in $lang.',
        ),
      );
      final reply = _Msg(false, '');
      setState(() => _msgs.add(reply));
      final history = _msgs.where((m) => m != reply && !m.error).toList();
      final prompt =
          'DATA:\n$data\n\nCONVERSATION:\n'
          '${history.map((m) => '${m.fromUser ? 'User' : 'Assistant'}: ${m.text}').join('\n')}';
      await for (final chunk in model.generateContentStream([
        Content.text(prompt),
      ])) {
        reply.text += chunk.text ?? '';
        if (mounted) setState(() {});
        _scrollDown();
      }
      if (reply.text.isEmpty) {
        reply.text = 'No answer came back. Please try again.';
      }
    } catch (e) {
      final msg = e.toString();
      setState(
        () => _msgs.add(
          _Msg(
            false,
            msg.contains('429') || msg.contains('RESOURCE_EXHAUSTED')
                ? 'The free AI quota is used up for now. Please try again later.'
                : 'Could not get an answer: $msg',
            error: true,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final name =
        ref.watch(companyProvider(widget.symbol)).value?.name ?? widget.symbol;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Ask AI')),
            Text(name, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              children: [
                if (_msgs.isEmpty) ...[
                  Text(
                    'Ask anything about $name. Answers use this company\'s results, '
                    'concall summaries, guidance, ownership and filings in the app.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in _suggestions)
                        ActionChip(label: Text(s), onPressed: () => _ask(s)),
                    ],
                  ),
                ],
                for (final m in _msgs)
                  Align(
                    alignment: m.fromUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.all(12),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.85,
                      ),
                      decoration: BoxDecoration(
                        color: m.fromUser
                            ? scheme.primaryContainer
                            : (m.error
                                  ? scheme.errorContainer
                                  : scheme.surfaceContainerHighest),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: m.text.isEmpty
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : SelectableText(m.text),
                    ),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(disclaimerText, style: TextStyle(fontSize: 10)),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _ask,
                      decoration: InputDecoration(
                        hintText: tr('Ask a question…'),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy ? null : () => _ask(_ctrl.text),
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
