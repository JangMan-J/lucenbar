# KDE Store listing (store.kde.org → Plasma 6 Extensions → Plasma 6 Applets)

**Name:** LucenBar Lite

**Category:** Plasma 6 Applets

**License:** MIT

**Version:** 1.0.0

**File:** `lucenbar-lite-1.0.0.plasmoid` from https://github.com/JangMan-J/lucenbar/releases/tag/v1.0.0

**Icon:** `docs/lucenbar-icon-store-512.png` (transparent, centered, 20% padding so the store does not clip it). Opaque alternative: `docs/lucenbar-icon-tile-512.png`.

**Tags:** ai, quota, usage, codex, claude, gemini, panel, plasma6

**Source / homepage:** https://github.com/JangMan-J/lucenbar

## Summary

AI provider quotas in your Plasma panel. A trimmed fork of CodexBar Plasma by Lucenx9.

## Description

LucenBar Lite shows how much of your AI provider quota you have left, directly in the Plasma 6 panel. It reads usage from the CodexBar CLI and works with Codex, Claude, Gemini/Antigravity, Grok, and the other providers the CLI supports.

**Panel:** bars, concentric rings, or provider logos that dim as quota runs out. Drag to reorder providers.

**Popup:** an Overview tab and one tab per provider, with every quota window, reset times, pace forecasts, and credits. Click a logo to show or hide that provider in the panel. Refresh, account, and login buttons per provider.

**Notifications:** warning and critical thresholds, optional meter coloring, and desktop notifications when a quota crosses a threshold, will run out before it resets, or resets.

**Requirements:** Plasma 6, python3, and the CodexBar CLI. If the CLI is not installed, click "Update now" in the widget's Providers settings to download the official Linux build. notify-send is needed for notifications.

**Credits:** LucenBar Lite is based on CodexBar Plasma (https://github.com/Lucenx9/codexbar-plasma) by Lucenx9, who wrote most of the code, the design, and the translations. If you want diagnostics, cost history, sessions, or multiple accounts, use the original: https://store.kde.org/p/2370789/

This fork removes those features and adds rings and logo meters, drag-to-reorder, and native login for Antigravity, Grok, and Radius. It is not maintained or endorsed by Lucenx9 or the CodexBar authors; please report problems at https://github.com/JangMan-J/lucenbar/issues, not upstream.

CodexBar CLI and most provider icons: CodexBar by Peter Steinberger (MIT). Poe provider icon: adapted (recolored) from "Poe App Logo" by SVG Stack (https://svgstack.com/icon/poe-app-logo-3748), licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).

## Changelog (1.0.0)

First release as LucenBar Lite, forked from CodexBar Plasma 0.2.50. See CHANGELOG.md.

## Screenshots (upload in this order)

1. `docs/lucenbar-overview.png` — Overview tab, panel in Rings style.
2. `docs/lucenbar-provider-tab.png` — Antigravity provider tab, panel in Bars style.
3. `docs/lucenbar-settings-display.png` — Display settings, Logos preview from full to empty.
