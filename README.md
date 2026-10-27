# Scout

The native iPhone app for ScoutAI: your morning briefing on tech, finance, world and fashion news, built in the same style as Halo and the calendar widget app. Same palettes and settings, same type, same cards and interactions, but all about news. There's no stocks tab.

- **Today**: the day's front page for your topic (Tech, Finance, World or Fashion): a cover with the lead picture, the AI overview, the top stories, Rumour watch, the companies to watch and In brief. Tech has a morning and an evening edition. Weather and live Tube status sit at the top.
  - Tap the date, or pull the page down, for a month calendar and go back to any earlier day. More dots mean a busier day; the accent dot means a briefing was written.
  - Tap **Edit** to drag cards into your own order, or hide the ones you don't want, as on Halo's Today.
- **News**: every story from about 100 sites. **All** is ranked by importance and your interests; Tech, Finance, World and Fashion open with that section's front page. Swipe sideways between sections; pull down for the latest.
- **Rumours**: unconfirmed stories with the AI's odds in Halo's ring, and the Confirmed and Denied ones. Sort by latest, most or least likely, or impact. The tab shows a badge for new rumours.
- **Saved**: bookmark any story; it stays even after it leaves the news.
- **Stories**: the picture, the AI summary with key points, the rumour check, the market impact (tap a company for every story that names it) and every outlet covering it. Swipe left and right between stories. The button at the bottom opens the original article in Safari, in Reader view if you like.
- **Settings**: the same Appearance section as Halo (Automatic, Light or Dark, six presets, your own colours for Light and Dark, four typefaces), your Today topic, news interests, weather location, Reader view and the morning briefing notification.
- **Widget**: your briefing's headline and top stories (small, medium, large and Lock Screen), in your colours.

SwiftUI, iOS 17+, no third-party libraries.

## Where the news comes from

Scout reads the same files as the ScoutAI web app: `data/news.json` and `data/briefing.json`, written twice a day by the updater in the [ScoutAI](https://github.com/ralphgeb/ScoutAI) repository. Nothing new needs to run: the app downloads them from

```
https://raw.githubusercontent.com/ralphgeb/ScoutAI/main/data
```

To point it somewhere else, change `SCOUT_DATA_URL` in `ScoutApp/project.yml`. The last good copy is kept on the iPhone, so the app opens straight away and works offline.

Weather comes from Open-Meteo and Tube status from TfL, both free and without keys, as in the web app.

## Project layout

```
ScoutApp/
  project.yml            XcodeGen project (app + widget extension)
  Sources/               the app
    ScoutApp.swift         entry point, tabs, background refresh, notifications
    NewsStore.swift        loading, caching, ranking, front pages, saved stories
    Common/ScoutPage.swift pinned date header, month calendar, scroll tracking (from Halo)
    Common/StoryViews.swift images, rows, hero cards, pills, the section switcher
    Today/                 front page cards, weather, Tube
    News/                  sections and section covers
    Rumours/               odds, Open / Confirmed / Denied
    Saved/                 bookmarks
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

GitHub Actions runs `Scout – build check` on every push (simulator build, no signing). `Scout – upload to TestFlight` is manual and needs the same four secrets as your other apps: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`, `APPLE_TEAM_ID`. Register the bundle IDs `com.ralphgeb.scout` and `com.ralphgeb.scout.widget` and the App Group `group.com.ralphgeb.scout` first.

## Good to know

- Summaries, odds and market effects are written by AI and can be wrong. Not financial advice.
- The morning notification depends on iOS waking the app in the background, so it usually arrives some time after 5:00 rather than at an exact minute.
