# Changelog

LucenBar Lite is a fork of
[CodexBar Plasma](https://github.com/Lucenx9/codexbar-plasma) v0.2.50 by
Lucenx9. For the history before the fork, see the
[upstream changelog](https://github.com/Lucenx9/codexbar-plasma/blob/main/CHANGELOG.md).

## 1.0.0

First release as LucenBar Lite.

### Changed

- Rename to LucenBar Lite with plugin ID `io.github.jangmanj.lucenbarlite`.
- Reduce settings to three pages: Providers, Display, Notifications. The
  Providers page holds refresh interval, refresh-on-open, and CLI update
  controls.
- Classify providers as Subscription (Log in) or Billed usage (API Key).
- Allow any number of providers in the panel, with drag-to-reorder in the panel
  and in the settings preview.
- Raise the maximum refresh interval to 24 hours.
- Enlarge provider logos in the popup: tabs from 16 to 22 px, Overview rows
  and the provider header from 32 to 40 px.
- Cache provider detection results so the Providers page opens with known
  status.

### Added

- LucenBar widget icon, shown in Add Widgets and the widget settings.
- Rings and Logos panel meter styles. Rings are drawn as five segments with
  8° gaps. With Logos, the Display settings preview shows the first selected
  provider's logo at five fill stages, full to empty.
- Click a provider logo in the popup to show or hide it in the panel.
- Keep named extra quota windows visible (dimmed) until they reset when a
  refresh omits them.
- Native login flows for Antigravity, Grok, and Radius; one-click login opens
  the browser directly.
- Radius provider with live balance and monthly cost.
- Complete de, es, fr, it, and pt_BR translations for the remaining strings.

### Fixed

- With Hide account names on, Overview quota rows keep their window names
  (such as "Gemini 5-hour") instead of showing "Usage".

### Removed

- Diagnostics, Usage & Spend, Sessions, AI Insights, support report, and usage
  sharing.
- Multi-account switching.
- Provider status and incident polling.
- Widget self-updater.
