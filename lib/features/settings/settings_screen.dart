import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';

const _concallExplainer = {
  'en':
      'A concall (conference call, or earnings call) is a call where a '
      "company's management explains its quarterly results to analysts and "
      'investors, then answers their questions. Listed companies in India must '
      'file the audio and transcript with NSE/BSE.',
  'bn':
      'কনকল (কনফারেন্স কল বা আর্নিংস কল) হল একটি কল যেখানে কোম্পানির '
      'ম্যানেজমেন্ট বিশ্লেষক ও বিনিয়োগকারীদের কাছে ত্রৈমাসিক ফলাফল ব্যাখ্যা করে '
      'এবং তাদের প্রশ্নের উত্তর দেয়। ভারতের তালিকাভুক্ত কোম্পানিগুলিকে এর অডিও ও '
      'ট্রান্সক্রিপ্ট NSE/BSE-তে জমা দিতে হয়।',
  'hi':
      'कॉनकॉल (कॉन्फ्रेंस कॉल या अर्निंग्स कॉल) वह कॉल है जिसमें कंपनी का '
      'मैनेजमेंट विश्लेषकों और निवेशकों को तिमाही नतीजे समझाता है और उनके सवालों के '
      'जवाब देता है। भारत में लिस्टेड कंपनियों को इसका ऑडियो और ट्रांसक्रिप्ट NSE/BSE '
      'पर जमा करना होता है।',
};

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(languageProvider);
    final repo = ref.watch(repositoryProvider);
    final push = ref.watch(firebaseEnabledProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          const SectionHeader('Summary language'),
          RadioGroup<String>(
            groupValue: lang,
            onChanged: (v) => ref.read(languageProvider.notifier).set(v!),
            child: Column(
              children: [
                for (final e in languageNames.entries)
                  RadioListTile<String>(value: e.key, title: Text(e.value)),
              ],
            ),
          ),
          const SectionHeader('What is a concall?'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_concallExplainer[lang] ?? _concallExplainer['en']!),
          ),
          const SectionHeader('Data'),
          ListTile(
            leading: const Icon(Icons.storage),
            title: Text(repo.isSample ? 'Sample data (offline)' : 'Live data'),
            subtitle: const Text(
              'Results come from XBRL filings on NSE/BSE. Concall summaries are '
              'AI-generated from the transcripts companies file.',
            ),
          ),
          ListTile(
            leading: Icon(
              push ? Icons.notifications_active : Icons.notifications_off,
            ),
            title: Text(push ? 'Push alerts on' : 'Push alerts unavailable'),
            subtitle: const Text('Star a stock to get alerts for it.'),
          ),
          const SectionHeader('Disclaimer'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: Text(disclaimerText),
          ),
        ],
      ),
    );
  }
}
