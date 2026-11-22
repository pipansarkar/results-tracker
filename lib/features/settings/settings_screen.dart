import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';

const _concallExplainer =
    'A concall (conference call) is a call where a company\'s management '
    'explains its results or business to analysts and investors, then answers '
    'their questions. Earnings calls follow quarterly results; analyst and '
    'investor calls happen in between. Listed companies in India must file the '
    'audio and transcript with NSE/BSE.';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final push = ref.watch(firebaseEnabledProvider);

    return Scaffold(
      appBar: AppBar(title: Text('More')),
      body: ListView(
        children: [
          SectionHeader('What is a concall?'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_concallExplainer),
          ),
          SectionHeader('Data'),
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
            subtitle: Text('Star a stock to get alerts for it.'),
          ),
          SectionHeader('Disclaimer'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: Text(disclaimerText),
          ),
        ],
      ),
    );
  }
}
