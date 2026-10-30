# Scout

The native iPhone app for ScoutAI: your morning briefing on tech, finance, world and fashion news, with live stocks, built in the same style as Halo and the calendar widget app: the same palettes and settings, type, cards and interactions. The icon (a hub of connected nodes, with ScoutAI's red dot) and the default **Scout** colours come from ScoutAI.

- **Today**: your **For you** front page: your biggest story on the cover, then your top stories (each says why: "Because you follow AI"), the companies to watch from your sections' briefings and more on your topics. Before you pick topics it shows one section's briefing. Weather (Apple WeatherKit: the next 12 hours as icons; tap for the 24-hour chart, and Apple Weather's credit is in Settings), live metro status for London, New York or Paris (folded at first; tap for every line) and the markets sit at the top.
  - Tap **Edit** to drag cards into your own order, or hide the ones you don't want, as on Halo's Today.
  - Every page has the same header: a big title with one line under it. Pull any page down to refresh.
- **News**: For you, Tech, Finance, World and Fashion. For you follows your topics, with the day's biggest stories mixed in and no more than three in a row on one topic; the four sections open with their AI summary as cards: the lead paragraph, then 4-6 highlights with a label in the accent (World and Finance give the US, the UK, Europe and Asia one each), then the stocks to watch; then the stories, newest first. World and Finance show the regions you follow (Settings › Regions). Each section keeps its own scroll position.
- **Stocks**: indices, the pound, bitcoin, gold and oil along the top; your stocks; the stocks in Scout's stories (15, then Show all); the top ten US companies. Prices update every 30 minutes on weekdays (7:00 to 22:30 UK time), and the page picks up each update while it's open. Tap a change to switch between %, the price change and market value. **Add** searches about 50,000 stocks, funds, indices, currencies and cryptos by name or ticker. A stock's page has a chart you can drag across (1D, 1M, 1Y), key numbers, the AI's "What's happening", headlines and every Scout story that names it.
- **History**: every story you've opened, grouped by day, with your saved stories one tap away. Kept after the stories leave the news.
- **Stories**: the picture, the AI summary with key points, the rumour check, the market impact (tap a company for every story that names it) and every outlet covering it. Swipe left and right between stories. The button at the bottom opens the original article in Safari.
- **Settings**: the same Appearance section as Halo (Automatic, Light or Dark, six presets, four typefaces, and a Custom colors page for your own main, text, accent, background and card colours in Light and Dark), your Today topic, news interests, weather location, metro city, with the morning briefing notification at the top.
- **Welcome**: on first launch, before any permission is asked: your topics and regions (bubbles, as in Apple News), the logo growing out of its centre in one movement, without its tile, then breathing gently, "Your morning news, simplified", how Scout works, and why it asks for your location (the weather). Then the Today topic.
- **Paywall preview** (Settings › Preview): the summaries stay open; the stories under them, More for you on Today, the stocks in the news, stock summaries and the stories on a stock's page sit under a light veil (you can still make them out) with one white lock per card, which opens a Scout Plus page. Nothing is sold.
- **Widget**: your briefing's headline and top stories (small, medium, large and Lock Screen), in your colours.

SwiftUI, iOS 17+, no third-party libraries.

## Where the news comes from

Scout reads the same files as the ScoutAI web app: `data/news.json` and `data/briefing.json`, written twice a day by the updater in the [ScoutAI](https://github.com/ralphgeb/ScoutAI) repository. Nothing new needs to run: the app downloads them from

```
https://raw.githubusercontent.com/ralphgeb/ScoutAI/main/data
```

To point it somewhere else, change `SCOUT_DATA_URL` in `ScoutApp/project.yml`. The last good copy is kept on the iPhone, so the app opens straight away and works offline.

Weather comes from Apple WeatherKit (Open-Meteo stands in if it can't answer) and metro status from TfL (London, read directly), the MTA (New York) and Île-de-France Mobilités (Paris), the last two through the Scout service, which asks once every two minutes for everyone. Settings › Metro for picks the city; Automatic uses the nearest of the three, or London.

### Stocks, kept live for free

- **Prices** come from ScoutAI's updater on GitHub every 30 minutes on weekdays (7:00 to 22:30 UK time). It publishes `stocks.json` to the Scout service on Cloudflare, and the phones read it from there; they never ask a price service themselves. So one small, steady update serves every user, whatever the number.
- **Instant summaries**: on iPhones with Apple Intelligence (iOS 26), a stock without Scout's summary gets a quick one written on the phone straight away, free and private.
- **AI summaries**: when someone adds a stock, the app tells a small Cloudflare Worker (`ScoutAI/stocks-worker`) that keeps the shared list of followed stocks. A brand-new stock starts ScoutAI's quick stocks update (at most every 10 minutes, if the `SCOUT_DISPATCH_TOKEN` secret is set), so its summary arrives within minutes; the morning update refreshes summaries for up to 120 of them, most recently followed first, so the AI cost stays at a few pence a day. A stock drops off the list 45 days after anyone last followed it. The worker runs on Cloudflare's free plan, which stops rather than charges.

## Project layout

```
ScoutApp/
  project.yml            XcodeGen project (app + widget extension)
  Sources/               the app
    ScoutApp.swift         entry point, tabs, background refresh, notifications
    NewsStore.swift        loading, caching, ranking, front pages, saved stories
    Common/ScoutPage.swift the pinned header and pull to refresh (from Halo)
    Common/StoryViews.swift images, rows, hero cards, pills, the section switcher
    Onboarding/            the welcome pages and the animated logo
    Today/                 front page cards, weather, metro status
    News/                  sections and section covers
    Stocks/                live prices, search, stock pages
    History/               stories you opened, and your saved ones
    Story/                 story pages, swiping between them, company pages
    Settings/              appearance, topic, interests, notifications
  Shared/                compiled into the app and the widget
    Appearance.swift       colour presets and custom palettes (the same as Halo's)
    Theme.swift            colours, type and the ring
    Models.swift           the shapes of news.json and briefing.json
    Feed.swift             downloads and cache, and the briefing digest for the widget
  Widget/                the briefing widget
  tools/make_icon.py     draws the app icon
```

## Build

On a Mac with Xcode 16 or later:

```
brew install xcodegen
cd ScoutApp
xcodegen generate
open Scout.xcodeproj
```

Pick your team under Signing & Capabilities for both targets, then run.

Before uploading: in your Apple developer account, open the App ID `com.ralphgeb.scout` and tick **WeatherKit** under both **Capabilities** and **App Services**, as for the calendar app.

GitHub Actions runs `Scout – build check` on every push (simulator build, no signing). `Scout – upload to TestFlight` is manual and needs the same four secrets as your other apps: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`, `APPLE_TEAM_ID`. Register the bundle IDs `com.ralphgeb.scout` and `com.ralphgeb.scout.widget` and the App Group `group.com.ralphgeb.scout` first.

## Good to know

- Summaries, odds and market effects are written by AI and can be wrong. Not financial advice.
- The morning notification depends on iOS waking the app in the background, so it usually arrives some time after 5:00 rather than at an exact minute.
