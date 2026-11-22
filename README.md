# Quarterly Results & Concall Tracker

Flutter app + Python pipeline for Indian listed companies: today's results,
results/concall calendar, quarterly history with YoY/QoQ, AI concall summaries
in English/বাংলা/हिंदी, a management guidance tracker, and watchlist push alerts.

**Running cost: ₹0.** Firebase Spark (free) plan, Gemini API free tier, GitHub Actions.

```
GitHub Actions (every 30 min)            Firebase (Spark, free)        Flutter app
  backend/run.py                          Firestore  ───────────────▶  reads ~1 doc per screen
   ├ NSE integrated filings → XBRL ───▶   companies/{symbol}
   ├ board meetings + intimation PDFs ─▶  calendar/{date}, feed/today
   ├ transcript PDF → Gemini summary ──▶  companies/{s}/concalls, guidance
   └ FCM topic push  ─────────────────▶   FCM  ──────────────────────▶  stock_<SYMBOL> topics
```

## Firebase config files (not in git)

`lib/firebase_options.dart`, `android/app/google-services.json` and
`ios/Runner/GoogleService-Info.plist` are git-ignored. After cloning, run
`flutterfire configure --project=results-tracker-dwpoz` to recreate them.

## Run the app now (sample data, no setup)

```bash
flutter run
```

With no Firebase config the app uses generated **sample data** and shows a banner
saying so. Tests: `flutter test`.

## Run the pipeline locally (no Firebase needed)

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest -q tests
# Real NSE data, written as JSON to backend/out/ (no push, no Firestore):
.venv/bin/python run.py --dry-run --backfill --symbols TCS,INFY --skip-transcripts
# With a Gemini key, also summarise queued transcripts:
GEMINI_API_KEY=... .venv/bin/python run.py --dry-run --days 7
```

## Go live (about 15 minutes, all free)

1. **Firebase project.** Go to <https://console.firebase.google.com>, then *Add project* (keep the free Spark plan).
   - *Build → Firestore Database → Create* (region `asia-south1` Mumbai).
   - *Rules* tab: paste `firestore.rules` and publish.
   - *Build → Authentication → Sign-in method*: enable **Anonymous**.
2. **Connect the app.**
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure        # pick the project, Android + iOS
   ```
   This creates `google-services.json` and `GoogleService-Info.plist`. The app then uses live
   Firestore automatically. For iOS push you also need an APNs key in Firebase → Cloud Messaging,
   which needs a paid Apple developer account. Android push is free.
3. **Service account.** In Firebase, go to *Project settings → Service accounts → Generate new private key*.
   **Never commit this file.**
4. **Gemini key.** Get a free key at <https://aistudio.google.com/apikey>.
5. **GitHub.** Push this repo, then go to *Settings → Secrets and variables → Actions* and add:
   - `FIREBASE_SERVICE_ACCOUNT`: the full JSON text of the key file
   - `GEMINI_API_KEY`
6. **First run.** Go to *Actions → results-pipeline → Run workflow*. Run it once with
   `--refresh-universe --backfill` to load the Nifty 500 list and about 3 years of history (slow, run it once).
   After that the schedule takes over.

## Free-tier limits to know

| Service | Limit | How the design copes |
|---|---|---|
| Firestore Spark | 50k reads / 20k writes per day | One doc per company/day/feed; calendar writes only on change |
| Gemini free tier | per-minute and per-day request caps ([current limits](https://ai.google.dev/gemini-api/docs/rate-limits)) | Max 8 summaries per run (`MAX_SUMMARIES`), rest queued; each transcript summarised once |
| GitHub Actions | Unlimited on **public** repos, 2,000 min/month on private | A run takes about 1–2 min. On a private repo, change the cron to hourly (`0 3-18 * * *`) |
| FCM | Free | Topic messages, no token storage |

Google may use free-tier Gemini inputs to improve its models. That's fine here, since transcripts are public filings.

## Known risks

- **NSE has no official API.** `backend/nse.py` calls the JSON endpoints that nseindia.com uses.
  They change occasionally. When a call fails, open the matching NSE page with browser dev tools
  and update the path. Since 2025, quarterly results are in **Integrated Filing (Financials)**.
  Older quarters come from the legacy `corporates-financial-results` endpoint.
- **NSE may block cloud IPs** (GitHub runners are in the US). If the Action logs show HTTP 403,
  run the same `run.py` on a free **Oracle Cloud Always Free** VM in the Mumbai region, or on any
  always-on PC, with a cron entry. Nothing else changes.
- Bank, NBFC and insurer XBRL uses different line items. Revenue and EBITDA fall back to interest
  earned and operating profit. Check these companies before trusting the figures.
- Scanned-image transcripts are skipped (no OCR in the free stack).

## Legal

Information only: no buy/sell calls and no price targets, which would fall under SEBI's Research Analyst rules.
Every summary links the original filing and carries an "AI may err" disclaimer.

## Layout

```
lib/
  models/models.dart          Firestore document models (shared field names with backend)
  data/                       Repository interface, Firestore + sample implementations, Riverpod providers
  features/                   today, calendar, watchlist, search, company (+charts), concall, settings
backend/
  run.py                      pipeline entrypoint
  nse.py / xbrl.py            NSE client, XBRL → quarterly numbers (₹ crore)
  announcements.py            transcript / concall-intimation detection, date & time parsing
  summarize.py                Gemini structured summary (EN/BN/HI, guidance, Q&A, red flags)
  guidance.py                 guidance vs actuals, credibility score
  store.py / notify.py        Firestore or local JSON; FCM topic push
  companies.csv               tracked companies (starter: Nifty 50; --refresh-universe → Nifty 500)
.github/workflows/pipeline.yml
firestore.rules
```
