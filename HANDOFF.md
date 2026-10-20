# LucenBar Lite — Handoff

Date: 2026-10-20
Base: upstream `codexbar-plasma` v0.2.50 (`Lucenx9`), paired with CodexBar CLI 0.78.0.
Source: `~/Projects/lucenbar` (git). Plugin ID: `io.github.jangmanj.lucenbarlite` (renamed from `app.codexbar.plasma` in 1.0.0; installs to `~/.local/share/plasma/plasmoids/io.github.jangmanj.lucenbarlite`). Build with `./package.sh`; store listing text is in `STORE.md`.

Upstream v0.2.50 can be fetched from `https://github.com/Lucenx9/codexbar-plasma/releases/download/v0.2.50/codexbar-plasma.plasmoid` if a pristine upstream reference is ever needed.

The new plugin ID means an upstream CodexBar Plasma install or update can no longer overwrite this widget. Existing panel instances of `app.codexbar.plasma` must be replaced with LucenBar Lite; their settings do not carry over.

---

## Purpose of the Fork

Strip the upstream widget down to its core job:
1. **Panel**: Quota at a glance (bars, concentric rings, or dimming provider logos) with drag-to-reorder.
2. **Popup**: Per-provider quota breakdown, overview tab, panel-visibility toggles, and one-click refresh/account/login actions.
3. **Notifications**: Configurable warning and critical quota thresholds with optional meter coloring and desktop notifications.

Everything else from upstream has been removed.

---

## Architecture & What Changed from Upstream v0.2.50

### 1. Removed Outright
- **Pages & surfaces**: General settings page (merged into the Providers header card), Diagnostics page, AI Insights page, support report generator, Usage & Spend (cost history, Codex token subtotals, SSH host), Sessions tab, Share-usage card.
- **Widget self-updater**: Removed UI, `update-widget.sh`, and update controllers.
- **Multi-account switching**: Removed `AccountsController` and `ProviderAccountsPanel` from the popup.
- **Provider status / incident polling**: Removed UI options and badges; `includeStatus` and `notifyStatusIncidents` are hardcoded to `false` in `contents/ui/main.qml`.
- **Popup clutter**: Removed row/section hide-and-restore toggles, changelog links, Docs/Dashboard/About action links, and the panel preview scenario selector (`Normal` / `Near limit` / `No data`).
- **Providers page clutter**: Removed source-mode dropdowns, descriptor field editors, and CLI command dumps (`reload()` queries `codexbar config providers --format json --json-only` directly without `--descriptors`).
- **Configuration schema**: `contents/config/main.xml` is trimmed to the 37 active keys (`refreshInterval` max raised to `86400` seconds).

---

### 2. Settings Dialog (`contents/config/config.qml` — 3 Pages)

1. **Providers (`contents/ui/configProviders.qml`)**:
   - **Header bar**: Search field, scanning indicator, `Show all` checkbox (defaults to showing only detected or enabled providers), and `Reload` button (forces a fresh provider list + `diagnoseAll` scan).
   - **Top surface card (`selectedProviderSurface`)** arranged in three aligned columns (no bottom footer bar):
     - **Left column**: Selected provider logo badge, display name, live tracking status dot + text (`Tracked via …`, `Not tracked`, `Checking…`), `Account` button, `Log in` (for subscription providers) or `API Key` (for billed-usage providers) button, and per-provider refresh button.
     - **Center column**: `CodexBar <version>` heading, `Update now` button, and `Update daily` checkbox (manages the private CLI at `~/.local/share/lucenbar/cli/current/codexbar`).
     - **Right column**: `Refresh:` editable minutes `SpinBox` (`1`–`1440` min, with hold/wheel step acceleration `1 → 2 → 5 → 10 → 30 → 60` and external `min` label) on the top row, and `On pop-up open` checkbox on the bottom row.
   - **Provider list (`components/ProviderConfigRow.qml`)**: Displays enabled and detected providers (ordered by `providerOrder`), subtitled with `"Subscription"` or `"Billed usage"` and an enable switch.

2. **Display (`contents/ui/configPanel.qml`)**:
   - **Panel preview (`components/PanelSettingsPreview.qml`)**: Renders `CompactRepresentation` at the live panel's measured thickness (`panelThickness`) with drag-to-reorder enabled, paired with the `Indicator size` slider (`panelMeterScale`, `0.5`–`1.0`, default `0.75`).
   - **Panel Appearance**:
     - `Meter style:` dropdown — `Bars` (*"Horizontal capsule bars, stacked per quota window."*), `Rings` (*"Concentric rings with session quota outside and weekly quota inside."*), or `Logos` (*"Provider logos act as the meters, dimming in brightness."*).
     - `Meter depth:` dropdown — `Single window` (`"primary"`) or `Dual windows` (`"auto"`).
   - **Panel Contents**: `Show meters`, `Show provider logos` (disabled when `Meter style` is `Logos`), `Show usage text (horizontal panels)`, `Text shows:` dropdown, `Add credits to the text`, `Auto-select the busiest provider`.
   - **Popup Appearance**: `Show percent used instead of percent left`, `Show reset times as clock times`, `Hide account names` (`cfg_privacyMode`).
   - **Popup Contents**: `Show pace forecasts`, `Show credits`, `Show details and charts`, `Label the tabs`.

3. **Notifications (`contents/ui/configNotifications.qml`)**:
   - **Thresholds**: `Warn at (% used):` spinbox, `Critical at (% used):` spinbox (floored at warning value), and `Color meters at warning thresholds` checkbox (`cfg_showQuotaWarningMarkers`).
   - **Notifications**: Master `Send notifications` checkbox plus indented toggles for `Quota reaches a threshold`, `Quota will run out before it resets`, and `Quota resets`.

---

### 3. Panel Representation (`contents/ui/components/CompactRepresentation.qml`)
- **Three meter styles (`panelMeterStyle`)**:
  - `bars`: Stacked horizontal capsules (`meterBarWidth × meterBarHeight`) next to the provider logo (`meterIconSize = 0.85 * meterExtent`).
  - `rings` (`components/QuotaRings.qml`): Up to two concentric rings (session outer, weekly inner) at `ringSize = meterExtent` next to the provider logo.
  - `logos` (`components/QuotaLogo.qml`): Standalone provider logo at full `ringSize` (no duplicate static icon beside it). Renders a 1px silhouette border that shifts along a 3-stop curve from Paper White (`#f6f3ec` at 100%) through Terracotta/Rust (`#b8522a`) to Burnt Oxide (`#4a1f18` at 0%), while the interior brand fill dims toward a warm oxide floor (`#381c17`).
- **Unlimited providers & drag-to-reorder**: `PanelProviders.maximumSelectableProviders` matches the full roster size. Dragging any meter in the panel or Display preview updates `providerOrder`.

---

### 4. Popup (`contents/ui/main.qml` & `contents/ui/components/FullRepresentation.qml`)
- **Tabs**: `Overview` tab plus one tab per enabled provider.
- **Panel visibility toggle**: Clicking the *selected* tab's logo, an Overview row's logo, or the provider header logo toggles that provider in or out of the panel (`panelProviderIDs`), dimming the logo to 30% opacity when hidden from the panel.
- **Overview rows**: Render all quota windows for each provider, including extra rate windows (such as Claude's `"Fable only"` or Antigravity's model-group summaries).
- **Carried extra windows (`UsageCache.js`)**: `UsageCache.withCarriedExtraRows` carries named extra windows forward (marked stale/dimmed) until their `resetsAt` passes if a subsequent refresh omits them (e.g., when Claude's OAuth usage endpoint rate-limits and falls back to CLI scrape). Extra window titles are persisted in `usageCache`.
- **Per-provider actions**: `Refresh`, `Account`, and `Log in` (or `API Key`). Both the popup and the Providers page execute `Log in` identically by starting the login helper and launching the default browser directly.

---

### 5. Provider Classification, Detection Cache & Auth Flows

- **Classification (`contents/ui/ProviderIdentity.js`)**:
  - `providerAccessKind()` classifies OAuth/session providers in `subscriptionProviders` as `"subscription"` (subtitled `"Subscription"`, action `"Log in"`) and keyed providers as `"api"` (subtitled `"Billed usage"`, action `"API Key"`).
  - Alibaba Coding Plan, Alibaba Token Plan, and Qwen Cloud are classified as billed usage (`"api"`).
  - `"pi"` is renamed **Radius** (`providerTitleOverrides`), classified as `"subscription"`, given its own icon (`contents/icons/providers/radius.svg`), and linked to `https://radius.earendil.com/`.
  - Antigravity's account URL (`providerLoginUrls` and `providerDashboardUrls`) is set to `https://gemini.google.com/app`.

- **Detection & tracking cache (`providerDetectionCache` in `configProviders.qml`)**:
  - Background scan runs `nice -n 10 codexbar diagnose --provider all --format json --redact` and caches `{ at, detected, diagnostics }` in `Plasmoid.configuration.providerDetectionCache`, flushing immediately via `Plasmoid.configuration.writeConfig()`.
  - `loadDetectionCache()` runs in `reload()` and before assigning `providers` / `selectedProviderID` in `handleListResult` so bindings never evaluate against an empty map on startup.
  - A cache is considered fresh (< 1 hour) only if every enabled provider has a diagnostic entry; if the selected enabled provider is uncached on open or after being toggled on, `loadProviderSettings()` immediately checks that single provider (~0.3–0.9s) while `diagnoseAll` runs in the background.
  - Single-provider diagnostic refreshes (`handleDiagnoseResult`) also persist into `providerDetectionCache`.

- **Login helper (`scripts/provider-login.py`)**:
  - Supports `start`, `status`, `submit`, and `cancel` for `"codex"`, `"claude"`, `"antigravity"`, `"grok"`, `"muse"`, and `"pi"`:
    - `codex`, `claude`, `muse`: Spawned under a detached PTY with a no-op `xdg-open` in `PATH` (`BROWSER=true`) so QML (`Qt.openUrlExternally`) is the sole browser launcher. Automatically sends `\n` when `muse login` prompts `"Press Enter to open"`. (**Note**: starting `codex login` invalidates the existing Codex token immediately.)
    - `antigravity`: Native Google OAuth PKCE runner (`https://accounts.google.com/o/oauth2/v2/auth` with callback `http://localhost:51121/oauth-callback`), saving tokens to `~/.pi/agent/auth.json`.
    - `grok`: Native xAI OAuth device-code runner (`POST https://auth.x.ai/oauth2/device/code` -> `https://accounts.x.ai/oauth2/device?user_code=...`, polling `https://auth.x.ai/oauth2/token`), writing credentials to both `~/.grok/auth.json` and `~/.pi/agent/auth.json`.
    - `pi` (Radius): Native PKCE runner (`https://radius.earendil.com/oauth/authorize` with callback `http://127.0.0.1:1456/oauth/callback` and `User-Agent: pi-coding-agent/1.0`), writing credentials to `~/.pi/agent/auth.json`.
  - `start()` cancels any prior lingering session and polls up to 4.0s (`0.1s` steps) until `url` is populated so the first response immediately opens the user's default browser without a separate `"Open link"` button.

- **Radius live balance & usage (`scripts/radius-usage.py` & `controllers/UsageController.qml`)**:
  - `UsageController.buildProviderUsageCommand("pi")` routes to `scripts/radius-usage.py`.
  - Obtains a fresh Radius bearer token (`pi auth print-bearer-token --provider radius` or `~/.pi/agent/auth.json` with refresh), calls `billing_summary_read` and `context_read` on `https://radius.pi.dev/mcp`, and returns a CodexBar snapshot with remaining credit balance (`Balance ($XX.XX)`), `credits.remaining`, current-month `providerCost`, and a `Billing` details table.

---

### 6. Localization (`contents/locale/`)
- Compiled `.mo` catalogs for `de`, `es`, `fr`, `it`, and `pt_BR` (`contents/locale/<lang>/LC_MESSAGES/plasma_applet_io.github.jangmanj.lucenbarlite.mo`) have been updated and recompiled with `msgfmt -c` to cover 100% of strings in the fork (457 singular `i18n` entries and 16 plural `i18np` entries).

---

## Environment & Development Notes
- **Widget instances**: the old `app.codexbar.plasma` instances (applets 234 and 236) were uninstalled on 2026-10-20. LucenBar Lite instances get new containment/applet IDs; update `dev/opencfg.js` (hardcoded panel `235`) after adding them. Since 1.0.0 the managed CLI lives at `~/.local/share/lucenbar/cli/current/codexbar` (was `~/.local/share/codexbar-plasma/cli/`). To migrate an existing install: `mv ~/.local/share/codexbar-plasma/cli ~/.local/share/lucenbar/cli` (create `~/.local/share/lucenbar` first) and repoint `~/.local/bin/codexbar` at the new path. Login sessions use `$XDG_RUNTIME_DIR/lucenbar/login/`.
- **Dev scripts (`dev/`)**:
  - `dev/cbcheck.sh <Page> <waitSeconds> <out.png>`: Restarts `plasma-plasmashell.service`, keeps panel 235 on screen 1 (`dev/movepanel.js`), opens Applet 236's settings (`dev/opencfg.js`), moves it to `(0, 60)`, and captures it via KWin `ScreenShot2` (`dev/capwin.py`).
  - Lint: `/usr/lib/qt6/bin/qmllint -I contents/ui -I /usr/lib/qt6/qml <file>`.
  - Logs: `journalctl --user -u plasma-plasmashell.service`.
