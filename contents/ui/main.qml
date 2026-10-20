import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid
import "components" as Components
import "controllers" as Controllers
import "Guards.js" as Guards
import "NotificationMemo.js" as NotificationMemo
import "NotificationPlanner.js" as NotificationPlanner
import "PacePresentation.js" as PacePresentation
import "PanelDisplay.js" as PanelDisplay
import "PanelElements.js" as PanelElements
import "PanelProviders.js" as PanelProviders
import "PopupSelection.js" as PopupSelection
import "ProviderAutoSelect.js" as ProviderAutoSelect
import "ProviderSnapshot.js" as ProviderSnapshot
import "CostPresentation.js" as CostPresentation
import "OverviewProviders.js" as OverviewProviders
import "ProviderIdentity.js" as ProviderIdentity
import "PrivacyPresentation.js" as PrivacyPresentation
import "ProviderNormalizer.js" as Normalizer
import "ProviderOrder.js" as ProviderOrder
import "UsageCache.js" as UsageCache
import "UsageState.js" as UsageState
import "ProviderViewModel.js" as ProviderViewModel
import "QuotaThresholds.js" as QuotaThresholds
import "SafeText.js" as SafeText
import "ThemeContrast.js" as ThemeContrast

PlasmoidItem {
    id: root

    Plasmoid.icon: String(Qt.resolvedUrl("../icons/lucenbar.svg"))
    Plasmoid.title: "LucenBar Lite"
    toolTipMainText: Plasmoid.title
    toolTipSubText: panelToolTipText()
    toolTipTextFormat: Text.PlainText
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refreshNow(true)
        }
    ]

    property string commandPath: (Plasmoid.configuration.commandPath || "codexbar").trim()
    // Local change: no provider/source overrides; the CLI decides.
    readonly property string provider: ""
    readonly property string source: ""
    property int refreshIntervalSec: isFinite(Number(Plasmoid.configuration.refreshInterval)) ? Math.max(0, Number(Plasmoid.configuration.refreshInterval)) : 300
    // Local change: provider status/incidents are not supported; never fetched.
    readonly property bool includeStatus: false
    property bool refreshOnOpen: Plasmoid.configuration.refreshOnOpen === true
    property bool showPopupPace: Plasmoid.configuration.showPopupPace !== false
    property bool showPopupCredits: Plasmoid.configuration.showPopupCredits !== false
    property bool showPopupProviderDetails: Plasmoid.configuration.showPopupProviderDetails !== false
    property bool privacyMode: Plasmoid.configuration.privacyMode === true
    readonly property var presentedProviders: providerPresentations(providers)
    readonly property var presentedOverviewProviders: providerPresentations(overviewProviderItems)
    readonly property var presentedProviderData: providerPresentation(selectedProviderData)
    // Resolved once: a .pragma library module cannot reach Qt.locale().
    readonly property var costNumberFormat: CostPresentation.numberFormat(
        Qt.locale().groupSeparator, Qt.locale().decimalPoint)
    property bool usageBarsShowUsed: Plasmoid.configuration.usageBarsShowUsed === true
    property bool showQuotaWarningMarkers: Plasmoid.configuration.showQuotaWarningMarkers !== false
    readonly property int quotaWarningPercent: QuotaThresholds.warningPercent(
        Plasmoid.configuration.quotaWarningPercent)
    // Derived from the warning step so a critical threshold configured below it
    // can never make the "major" level unreachable.
    readonly property int quotaCriticalPercent: QuotaThresholds.criticalPercent(
        quotaWarningPercent,
        Plasmoid.configuration.quotaCriticalPercent)
    property bool enableNotifications: Plasmoid.configuration.enableNotifications !== false
    readonly property bool notifyStatusIncidents: false
    property bool notifyQuotaWarnings: Plasmoid.configuration.notifyQuotaWarnings !== false
    property bool notifyPredictivePaceWarnings: Plasmoid.configuration.notifyPredictivePaceWarnings === true
    property bool notifyLimitResets: Plasmoid.configuration.notifyLimitResets === true
    property string menuBarDisplayMode: safeMenuBarDisplayMode(Plasmoid.configuration.menuBarDisplayMode)
    property bool showPopupTabLabels: Plasmoid.configuration.showPopupTabLabels !== false
    property string providerOrderRaw: Plasmoid.configuration.providerOrder || ""
    property string panelProviderIDsRaw: Plasmoid.configuration.panelProviderIDs || ""
    readonly property bool minimalPanel: false
    readonly property bool ringMeters: Plasmoid.configuration.panelMeterStyle === "rings"
    readonly property bool logoMeters: Plasmoid.configuration.panelMeterStyle === "logos"
    readonly property bool panelProviderIcons: Plasmoid.configuration.showProviderIconsInPanel !== false
    readonly property real panelMeterScale: {
        var value = Number(Plasmoid.configuration.panelMeterScale)
        return isFinite(value) && value > 0 ? Math.min(1, Math.max(0.5, value)) : 0.75
    }
    readonly property string panelQuotaLane: PanelDisplay.safeLane(Plasmoid.configuration.panelQuotaLane)
    property bool resetTimesShowAbsolute: Plasmoid.configuration.resetTimesShowAbsolute === true
    property bool autoSelectProvider: Plasmoid.configuration.autoSelectProvider === true
    property string overviewProviderIDsRaw: Plasmoid.configuration.overviewProviderIDs || ""
    property int providerConfigRevision: boundedConfigRevision(Plasmoid.configuration.providerConfigRevision)
    property var providers: []
    readonly property var providerDisplayNames: usageController.providerDisplayNames
    readonly property string errorText: usageController.errorText
    readonly property bool commandPathFailed: usageController.commandPathFailed
    property string lastUpdatedText: ""
    property bool usageLifecycleInitialized: false
    readonly property string usageIdentityContext: JSON.stringify([
        commandPath, provider, source, providerConfigRevision])
    readonly property bool loading: usageController.loading
    // Reset labels and run-out durations keep moving even when automatic CLI
    // refresh is disabled. Each row's receipt time anchors forecast durations;
    // unrelated refreshes must not restart that countdown.
    property double panelClockMs: Date.now()
    readonly property int panelClockIntervalMs: 60000
    readonly property string commandSource: usageController.commandSource
    property string providerConfigStamp: ""

    property string selectedProviderID: ""
    // Provider meter currently under the panel pointer. The plasmoid tooltip
    // narrows to this provider while it is set, so hovering one panel icon
    // reports only that provider instead of the whole roster.
    property string hoveredPanelProviderID: ""
    property string selectedGlobalView: "overview"
    property bool selectionInitialized: false
    property var selectedAccounts: ({})
    property var notificationMemo: ({})
    property var notificationRefreshPending: ({})
    property bool notificationsPrimed: false
    readonly property bool verticalFormFactor: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property var overviewProviderItems: overviewProviders()
    readonly property bool globalNavigationAvailable: provider.length === 0
    readonly property bool overviewAvailable: globalNavigationAvailable && providers.length > 1 && overviewProviderItems.length > 0
    readonly property int selectedProviderIndex: providerIndexForID(selectedProviderID)
    readonly property bool globalViewSelected: selectionInitialized && selectedProviderID.length === 0
    readonly property bool overviewSelected: overviewAvailable && globalViewSelected && selectedGlobalView === "overview"
    readonly property var selectedProviderData: providers.length > 0 && selectedProviderIndex >= 0
        ? providers[Math.min(selectedProviderIndex, providers.length - 1)]
        : null
    readonly property real roundedSurfaceRadius: Kirigami.Units.cornerRadius
        + Kirigami.Units.smallSpacing
    // Radius for a small surface drawn inside a roundedSurfaceRadius container.
    // Concentric rounding wants the inner radius reduced by the inset between
    // the two edges, and popup surfaces inset their content by smallSpacing, so
    // this is roundedSurfaceRadius minus that inset by construction.
    readonly property real nestedSurfaceRadius: Kirigami.Units.cornerRadius
    // Two-step de-emphasis scale for popup text. A supporting label uses the
    // secondary step and the value it annotates uses the stronger step, so a
    // label/value pair keeps its hierarchy without inventing a new opacity per
    // section. 0.7 is the lowest step where Kirigami.Theme.textColor still
    // clears WCAG AA 4.5:1 against the Breeze Light popup background.
    readonly property real secondaryTextOpacity: 0.7
    readonly property real valueTextOpacity: 0.85
    // Shared track height for the credits, cost, and usage meters that stack in
    // one provider detail view. Derived from gridUnit so it follows the user
    // font size instead of pinning a device pixel count.
    readonly property real meterTrackHeight: Math.round(Kirigami.Units.gridUnit * 0.4)
    // Thinner track for meters that sit inside a scannable list row (overview
    // rows, cost history rows) instead of leading a detail section. Keeping the
    // two scales apart is what makes the primary meters read as primary.
    readonly property real compactMeterTrackHeight: Math.round(Kirigami.Units.gridUnit * 0.28)

    onUsageIdentityContextChanged: {
        invalidateUsageData()
        scheduleUsageRefresh()
    }
    onProviderOrderRawChanged: providers = ProviderOrder.orderedItems(
        providers, providerOrderRaw)
    onAutoSelectProviderChanged: updateSelectedProvider()
    onOverviewProviderIDsRawChanged: updateSelectedProvider()
    onOverviewAvailableChanged: reconcileGlobalViewAvailability()
    onEnableNotificationsChanged: resetNotificationMemo()
    onNotifyStatusIncidentsChanged: resetNotificationMemo()
    onNotifyQuotaWarningsChanged: resetNotificationMemo()
    onNotifyPredictivePaceWarningsChanged: resetNotificationMemo()
    // The memo stores the level each row was last observed at. Keeping it across
    // a threshold change would suppress a warning the new lower threshold should
    // raise, and leave a row armed at a level the new higher threshold no longer
    // reaches.
    onQuotaWarningPercentChanged: resetNotificationMemo()
    onQuotaCriticalPercentChanged: resetNotificationMemo()
    onNotifyLimitResetsChanged: resetNotificationMemo()
    onProvidersChanged: {
        if (providers.length === 0) {
            hoveredPanelProviderID = ""
            updateSelectedProvider()
            resetNotificationMemo()
            return
        }
        if (hoveredPanelProviderID.length > 0 && providerIndexForID(hoveredPanelProviderID) < 0) {
            hoveredPanelProviderID = ""
        }
        updateSelectedProvider()
        Qt.callLater(processNotifications)
    }

    Component.onCompleted: {
        usageLifecycleInitialized = true
    }

    function safeMenuBarDisplayMode(value) {
        return PanelDisplay.safeMode(value)
    }

    function panelElementOrder() {
        return PanelElements.defaultOrder
    }

    function boundedConfigRevision(value) {
        var revision = Number(value)
        if (!isFinite(revision)) {
            return 0
        }
        return Math.max(0, Math.min(2147480000, Math.floor(revision)))
    }

    function boundedCliMessage(value) {
        return SafeText.cliMessage(SafeText.stripLoaderDiagnostics(value), SafeText.maximumCliMessageLength)
    }

    function isCliRecord(value) {
        return Normalizer.isCliRecord(value)
    }

    function normalizedProviderID(value) {
        return Normalizer.normalizedProviderID(value)
    }

    function hasOwnKey(item, key) {
        return Guards.hasOwnKey(item, key)
    }

    function isUnsafeObjectKey(key) {
        return Guards.isUnsafeObjectKey(key)
    }

    function providerMapKey(providerID) {
        return Normalizer.providerSnapshotKey(providerID)
    }

    function refreshNow(bypassProviderRosterCache) {
        usageController.refresh(bypassProviderRosterCache)
    }

    function scheduleUsageRefresh() {
        usageController.scheduleRefresh()
    }

    function retryUsage() {
        if (!loading) {
            root.refreshNow(true)
        }
    }

    function markUsageSnapshotReceived(nowMs) {
        nowMs = nowMs === undefined ? Date.now() : nowMs
        panelClockMs = nowMs
    }

    function usageCacheContext() {
        if (providerConfigStamp.length === 0 || commandSource.length === 0) {
            return ""
        }
        var accounts = Object.keys(selectedAccounts).sort().map(function(key) {
            return [key, root.selectedAccounts[key]]
        })
        return Qt.md5(JSON.stringify([usageIdentityContext, accounts, providerConfigStamp]))
    }

    // The sole cache writer. Pure transitions decide data and label semantics;
    // QML retains notification ordering, localization and configuration effects.
    function applyUsageTransition(result) {
        if (!result) {
            return
        }
        if (result.refreshCompleted) {
            markNotificationProvidersFresh(result.providers)
        }
        if (result.receivedFreshUsage) {
            markUsageSnapshotReceived(result.nowMs)
        }
        providers = result.providers
        switch (result.label) {
        case "stale":
            lastUpdatedText = i18n("Showing last known usage")
            break
        case "updated":
            lastUpdatedText = i18n("Updated %1", timeLabels.clockTime(result.nowMs))
            break
        case "clear":
            lastUpdatedText = ""
            break
        }
        if (result.cacheValue !== null) {
            Plasmoid.configuration.usageCache = result.cacheValue
        }
        if (result.advanceClock) {
            panelClockMs = result.nowMs
        }
    }

    function invalidateUsageData(providerID) {
        if (!usageLifecycleInitialized) {
            return
        }
        usageController.reset()
        applyUsageTransition(UsageState.invalidated(providers, providerID,
            providerID ? normalizeProvider({provider: providerID}) : null,
            usageCacheContext(), Date.now()))
    }

    function restoreUsageCache() {
        var context = usageCacheContext()
        if (context.length === 0) {
            return
        }
        var nowMs = Date.now()
        var restored = UsageCache.decode(Plasmoid.configuration.usageCache, context, nowMs)
        var cachedProviders = restored.map(function(payload) {
            var item = root.normalizeProvider(payload)
            item.lastGoodAtMs = Date.parse(payload.usage.updatedAt)
            item.usageStale = true
            return item
        })
        applyUsageTransition(UsageState.restored(providers, cachedProviders,
            selectedAccounts, providerOrderRaw, context, nowMs))
    }

    function commitUsageSnapshot(items) {
        applyUsageTransition(UsageState.accepted(providers, items, usageCacheContext(), Date.now()))
    }

    function failUsageRefresh(message) {
        var nowMs = Date.now()
        var failures = providers.map(function(item) {
            return root.normalizeProvider(root.providerErrorPayload(item.provider, message))
        })
        applyUsageTransition(UsageState.failed(providers, failures, usageCacheContext(), nowMs))
    }

    function expireStaleUsage(nowMs) {
        var expired = UsageCache.expiredProviderIDs(providers, nowMs)
        if (expired.length === 0) {
            return
        }
        var replacements = providers.filter(function(item) {
            return expired.indexOf(item.provider) >= 0
        }).map(function(item) {
            return root.normalizeProvider(root.providerErrorPayload(item.provider,
                item.error || i18n("Cached usage has expired. Refresh to try again.")))
        })
        applyUsageTransition(UsageState.expired(providers, replacements, usageCacheContext(), nowMs))
    }

    function lastGoodUsageText(item) {
        var ageSeconds = Math.max(0, (panelClockMs - item.lastGoodAtMs) / 1000)
        return ageSeconds < 60 ? i18n("Last known usage, just now")
            : i18n("Last known usage, %1 ago", paceEtaText(ageSeconds))
    }

    function providerUsageTimestamp(item) {
        if (!item || !(item.lastGoodAtMs > 0)) {
            return ""
        }
        return item.usageStale === true ? lastGoodUsageText(item)
            : i18n("Updated %1", timeLabels.clockTime(item.lastGoodAtMs))
    }

    function handleProviderConfigObservation(stamp, initial) {
        providerConfigStamp = stamp
        if (initial) {
            restoreUsageCache()
            return
        }
        invalidateUsageData()
        scheduleUsageRefresh()
    }

    function providerErrorPayload(providerID, message) {
        return {
            provider: providerID,
            source: source.length > 0 ? source : "auto",
            error: {
                code: 1,
                kind: "provider",
                message: message
            }
        }
    }

    // "Just now", "5 minutes ago", "2 days ago": the popup's relative age.
    function elapsedText(sinceMs, nowMs) {
        var currentTimeMs = Number(nowMs)
        if (!isFinite(currentTimeMs) || currentTimeMs <= 0) {
            currentTimeMs = Date.now()
        }
        var elapsedSeconds = Math.max(0, Math.floor((currentTimeMs - sinceMs) / 1000))
        if (elapsedSeconds < 60) {
            return i18n("Just now")
        }
        var minutes = Math.floor(elapsedSeconds / 60)
        if (minutes < 60) {
            return i18np("%1 minute ago", "%1 minutes ago", minutes)
        }
        var hours = Math.floor(minutes / 60)
        if (hours < 24) {
            return i18np("%1 hour ago", "%1 hours ago", hours)
        }
        var days = Math.floor(hours / 24)
        return i18np("%1 day ago", "%1 days ago", days)
    }

    function dashboardLabelText(labelKey) {
        return costText.dashboardLabelText(labelKey)
    }

    function dashboardPartText(part) {
        return costText.dashboardPartText(part)
    }

    function dashboardDisplayRow(row) {
        return costText.dashboardDisplayRow(row)
    }

    function selectedAccountForProvider(providerID) {
        var key = providerMapKey(providerID)
        if (key.length === 0) {
            return ""
        }
        var selected = selectedAccounts[key]
        return selected ? String(selected) : ""
    }

    function privateErrorText(text) {
        return PrivacyPresentation.errorText(text, privacyMode,
            i18n("Details hidden by privacy mode."))
    }

    function accountDisplayLabel(item, index) {
        return privacyMode ? i18n("Account %1", index + 1) : accountLabel(item)
    }

    function providerPresentations(items) {
        return items.map(function(item) { return root.providerPresentation(item) })
    }

    function providerPresentation(item) {
        if (!privacyMode || !item) {
            return item
        }
        var result = PrivacyPresentation.provider(item, true, {
            title: providerDisplayTitle(item.provider),
            account: i18n("Account hidden"),
            status: statusBadgeText(item.statusSeverity),
            error: i18n("Details hidden by privacy mode."),
            placeholder: i18n("No usage yet"),
            usage: i18n("Usage"),
            // Quota window names (lane titles, extra windows such as "Gemini
            // 5-hour") identify no account, so privacy mode keeps them.
            rowLabels: (item.rows || []).map(function(row) {
                return typeof row.label === "string" && row.label.length > 0 ? row.label
                    : rateWindowLabels.labelForLane(providerKey(item.provider), row.lane, row.cliLabel)
            })
        })
        for (var i = 0; i < result.rows.length; i++) {
            result.rows[i].pace = paceSummaryPartsText(result.rows[i].paceParts)
        }
        return result
    }

    function popupDetailSections(item) {
        return item && Array.isArray(item.providerDetails) ? item.providerDetails : []
    }

    function popupUsageRows(item) {
        return item && Array.isArray(item.rows) ? item.rows : []
    }

    function accountLabel(item) {
        return Normalizer.accountLabel(item)
    }

    // The stable account selection identity. Display labels may collapse spacing
    // that still distinguishes two accounts, so selection, matching, and the
    // CLI argument or enumerated Codex result compare keys, never labels.
    function accountKey(item) {
        return Normalizer.accountKey(item)
    }

    function accountSubtitle(item) {
        if (privacyMode || !item) {
            return ""
        }
        var parts = []
        if (item.loginMethod && item.loginMethod.length > 0) {
            parts.push(item.loginMethod)
        }
        if (item.organization && item.organization.length > 0 && item.organization !== item.account) {
            parts.push(item.organization)
        }
        return parts.join(" · ")
    }

    function accountIsSelected(option, currentItem) {
        if (!option) {
            return false
        }
        var identity = accountKey(option)
        var selected = selectedAccountForProvider(option.provider)
        if (selected.length > 0) {
            return identity.length > 0 && identity === selected
        }
        // A presented snapshot may replace the account label with a placeholder.
        // Selection always compares against the original account identity.
        var currentIndex = currentItem ? providerIndexForID(currentItem.provider) : -1
        var accountItem = currentIndex >= 0 ? providers[currentIndex] : currentItem
        return accountItem && accountItem.provider === option.provider && identity.length > 0 && identity === accountKey(accountItem)
    }

    function replaceProviderSnapshot(providerID, snapshot) {
        var key = providerMapKey(providerID)
        if (key.length === 0) {
            return
        }
        var replacement = UsageCache.reconcile([], [snapshot], Date.now())[0]
        var nextProviders = []
        for (var i = 0; i < providers.length; i++) {
            nextProviders.push(providers[i].provider === key ? replacement : providers[i])
        }
        if (!nextProviders.some(function(item) { return item.provider === key })) {
            nextProviders.push(replacement)
        }
        providers = ProviderOrder.orderedItems(nextProviders, providerOrderRaw)
    }

    function normalizeProvider(item) {
        return presentProviderSnapshot(ProviderSnapshot.normalize(item, Date.now()))
    }

    function presentProviderSnapshot(snapshot) {
        var providerID = snapshot.provider
        var dashboard = snapshot.usageDashboard
        return ProviderViewModel.presented(snapshot, {
            title: providerTitle(providerID,
                snapshot.displayName === null ? providerDisplayNames[providerID] : snapshot.displayName),
            rows: snapshot.rows.map(function(row) { return root.presentUsageWindow(row, providerID) }),
            usageDashboard: dashboard ? {kpis: dashboard.kpis.map(dashboardDisplayRow), rows: dashboard.rows.map(dashboardDisplayRow)} : null,
            providerCost: providerCostSection(providerID, snapshot.providerCost),
            resetCredits: resetCreditsSection(providerID, snapshot.resetCredits),
            planText: planText(providerID, snapshot.planMethod),
            dashboardUrl: providerDashboardUrl(providerID),
            statusUrl: safeStatusUrl(providerID, snapshot.statusUrl),
            status: snapshot.statusRecord ? statusText(snapshot.statusRecord) : "",
            error: snapshot.commandFailed ? (snapshot.error || i18n("codexbar command failed.")) : "",
            placeholder: snapshot.placeholder === "limitsUnavailable" ? i18n("Limits not available")
                : (snapshot.placeholder === "noUsage" ? i18n("No usage yet") : "")
        })
    }

    function subscriptionDateText(date) {
        var value = timeLabels.subscriptionDate(date)
        return date.kind === "renews" ? i18n("Plan renews on %1", value) : i18n("Plan expires on %1", value)
    }

    function presentUsageWindow(snapshot, providerID) {
        var row = copyObject(snapshot)
        row.label = snapshot.label !== null ? snapshot.label
            : (snapshot.lane === "extra" ? i18n("Extra") : rateWindowLabels.labelForLane(providerKey(providerID), snapshot.lane, snapshot.cliLabel))
        row.reset = Normalizer.boundedDisplayText(resetText({resetsAt: snapshot.resetValue,
            resetDescription: snapshot.resetDescription}, false), 500)
        row.pace = paceSummaryPartsText(snapshot.paceParts)
        delete row.resetValue
        return row
    }

    // The popup pace line. Its run-out forecast counts down from the row's
    // observation like the panel, instead of repeating the receipt-time ETA.
    function usagePaceText(row) {
        if (!row || !row.pace) {
            return ""
        }
        return Array.isArray(row.paceParts)
            ? paceSummaryPartsText(PacePresentation.advancedParts(row.paceParts, row.paceObservedAtMs, panelClockMs))
            : row.pace
    }


    function providerCostSection(providerID, cost) {
        return providerCostDetails.costSection(providerID, cost)
    }

    function resetCreditsSection(providerID, resetCredits) {
        return providerCostDetails.resetSection(providerID, resetCredits)
    }

    function codexCreditLimitUsageRow(creditLimit) {
        return providerCostDetails.creditLimitRow(creditLimit)
    }

    function resetText(window, absolute) {
        return usageWindowText.resetText(window, panelClockMs, absolute)
    }

    function usageResetText(row) {
        row = PrivacyPresentation.quota(row, privacyMode, "")
        if (!Normalizer.canPresentQuotaDetails(row)) {
            return ""
        }
        if (row.resetsAt || row.resetDescription) {
            return resetText({
                resetsAt: row.resetsAt || "",
                resetDescription: row.resetDescription || ""
            }, resetTimesShowAbsolute)
        }
        var fallback = String(row.reset || "")
        return fallback.length === 0 && row.hasPercent
            && Normalizer.usageConfidence(row.dataConfidence) === "percentOnly"
            ? i18n("Reset unavailable") : fallback
    }

    function statusText(status) {
        // Status fields are CLI-controlled: read them without coercing objects,
        // whose missing toString would throw inside String().
        var indicator = Normalizer.safeScalarText(status.indicator)
        var description = Normalizer.safeScalarText(status.description).trim()
        if (indicator.length === 0 || indicator === "none") {
            return description
        }

        var labels = {
            "minor": i18n("Partial outage"),
            "major": i18n("Major outage"),
            "critical": i18n("Critical issue"),
            "maintenance": i18n("Maintenance"),
            "unknown": i18n("Status unknown")
        }
        var text = Guards.hasOwnKey(labels, indicator) ? labels[indicator] : indicator
        return description.length > 0 ? text + ": " + description : text
    }

    function statusBadgeColor(severity) {
        switch (String(severity || "")) {
        case "critical":
        case "major":
            return Kirigami.Theme.negativeTextColor
        case "minor":
        case "maintenance":
            return Kirigami.Theme.neutralTextColor
        case "unknown":
            return Kirigami.Theme.textColor
        default:
            return "transparent"
        }
    }

    function statusBadgeText(severity) {
        switch (String(severity || "")) {
        case "critical":
            return i18n("Critical")
        case "major":
            return i18n("Major")
        case "minor":
            return i18n("Issue")
        case "maintenance":
            return i18n("Maint.")
        case "unknown":
            return i18n("Unknown")
        default:
            return ""
        }
    }

    function primaryIncidentProvider() {
        var best = null
        var bestRank = 0
        for (var i = 0; i < providers.length; i++) {
            var item = providers[i]
            if (!item || item.statusKnown === false || item.hasIncident !== true) {
                continue
            }
            var rank = NotificationMemo.severityRank(item.statusSeverity)
            if (rank > bestRank) {
                best = item
                bestRank = rank
            }
        }
        return best
    }

    function quotaWarningMarkers(row) {
        if (!showQuotaWarningMarkers || !row || !row.hasPercent || !Normalizer.authoritativeQuota(row)) {
            return []
        }
        return QuotaThresholds.markers(
            quotaWarningPercent,
            quotaCriticalPercent,
            usageBarsShowUsed)
    }

    // The thresholds used to surface only as two ticks on the provider detail
    // meter, so an almost exhausted window looked exactly like an idle one on
    // the panel and in the overview. Every meter fill reads its colour from
    // this one level; the provider accent stays in charge below the warning
    // step, and the same setting that hides the markers hides the colour.
    function quotaSeverity(row) {
        if (!showQuotaWarningMarkers || !row || !row.hasPercent || !Normalizer.authoritativeQuota(row)) {
            return ""
        }
        return QuotaThresholds.level(row.usedPercent, quotaWarningPercent, quotaCriticalPercent)
    }

    function quotaMeterColor(row, accent) {
        var severity = quotaSeverity(row)
        return severity.length > 0 ? statusBadgeColor(severity) : accent
    }

    // Quota, pace, and reset memo state is threshold-derived and has to be
    // rebuilt whenever a setting changes. Provider status is not: a settings
    // change is not a status transition, so the status baseline survives the
    // reset. Dropping it would either re-announce an ongoing incident or, once
    // the first observation is silently primed, swallow an incident that starts
    // while the provider is still refreshing.
    function resetNotificationMemo() {
        notificationMemo = NotificationPlanner.transition(
            [], notificationMemo, ({ mode: "reset" })).nextMemo
        notificationsPrimed = false
        // Prime synchronously against the current snapshot so an incident that
        // starts between the reset and the next deferred pass cannot be
        // absorbed silently into the new baseline. The deferred call stays as
        // a coalesced follow-up for refreshes already in flight.
        processNotifications()
        Qt.callLater(processNotifications)
    }

    function notificationProviderRefreshPending(providerID) {
        var key = providerMapKey(providerID)
        return key.length > 0 && notificationRefreshPending[key] === true
    }

    function setNotificationProviderRefreshPending(providerID, pending) {
        var key = providerMapKey(providerID)
        if (key.length === 0) {
            return
        }
        var nextPending = copyObject(notificationRefreshPending)
        if (pending) {
            nextPending[key] = true
        } else {
            delete nextPending[key]
        }
        notificationRefreshPending = nextPending
    }

    function markNotificationProvidersFresh(items) {
        var nextPending = copyObject(notificationRefreshPending)
        for (var i = 0; i < items.length; i++) {
            var item = items[i]
            if (!item || (item.usageStale === true && item.statusKnown !== true)) {
                continue
            }
            var providerID = providerMapKey(item.provider)
            if (providerID.length === 0) {
                continue
            }
            var selectedAccount = selectedAccountForProvider(providerID)
            if (selectedAccount.length > 0 && accountKey(item) !== selectedAccount) {
                continue
            }
            // A failed account refresh can still carry fresh provider status.
            // The planner separately ignores missing quota evidence.
            delete nextPending[providerID]
        }
        notificationRefreshPending = nextPending
    }

    function notificationScopeKey(item) {
        if (!item) {
            return JSON.stringify(["", ""])
        }
        var providerID = providerMapKey(item.provider)
        var selectedAccount = selectedAccountForProvider(providerID)
        var currentAccount = selectedAccount.length > 0 ? selectedAccount : accountKey(item)
        return JSON.stringify([providerID, currentAccount])
    }

    function paceWarningActive(row) {
        return row && Normalizer.authoritativeQuota(row) && row.paceOnTop === false && Number(row.paceEtaSeconds) > 0
    }

    function paceSummaryText(pace) {
        return paceSummaryPartsText(PacePresentation.summaryParts(pace))
    }

    function paceSummaryPartsText(parts) {
        return usageWindowText.paceSummaryPartsText(parts)
    }

    function paceEtaText(seconds) {
        return usageWindowText.paceEtaText(seconds)
    }

    // Usage at or above this percent arms a row for reset detection; once armed,
    // dropping to or below the floor fires a single "limit reset" notification.
    // Mirrors the macOS weekly-limit reset detector, scoped to limits the user
    // was actually near so routine short-window resets stay quiet.
    readonly property int limitResetArmThreshold: 80
    readonly property int limitResetFloor: 5

    function quotaNotificationLevel(row) {
        if (!row || !row.hasPercent || !Normalizer.authoritativeQuota(row)) {
            return ""
        }
        return QuotaThresholds.level(
            row.usedPercent,
            quotaWarningPercent,
            quotaCriticalPercent)
    }

    // QML resolves account identity, refresh freshness, configured thresholds,
    // and the rows to display. The pure planner receives only semantic
    // observations and returns ordered intents; it never sees i18n or effects.
    function notificationObservationRows(item) {
        if (item && item.usageStale === true) {
            return []
        }
        var sourceRows = item && Array.isArray(item.rows) ? item.rows : []
        var result = []
        for (var i = 0; i < sourceRows.length; i++) {
            var row = sourceRows[i]
            result.push({
                lane: row && row.lane ? String(row.lane) : "",
                windowId: row ? Normalizer.extraWindowID(row.windowId) : "",
                label: row && row.label ? String(row.label) : "",
                resetsAt: row && row.resetsAt ? String(row.resetsAt) : "",
                hasPercent: row && row.hasPercent === true,
                dataConfidence: row ? row.dataConfidence : "",
                usedPercent: row ? Number(row.usedPercent) : NaN,
                quotaLevel: quotaNotificationLevel(row),
                paceKnown: row && row.paceKnown === true,
                paceActive: paceWarningActive(row)
            })
        }
        return result
    }

    function notificationObservations() {
        var result = []
        for (var i = 0; i < providers.length; i++) {
            var item = providers[i]
            if (!item) {
                continue
            }
            var rows = notificationObservationRows(item)
            result.push({
                providerIndex: i,
                providerID: providerMapKey(item.provider),
                scopeID: notificationScopeKey(item),
                pending: NotificationPlanner.observationPending(
                    (item.usageStale === true && item.statusKnown !== true)
                        || notificationProviderRefreshPending(item.provider),
                    String(item.error || "").length > 0,
                    item.statusKnown === true,
                    rows.length),
                errorPresent: String(item.error || "").length > 0,
                usageStale: item.usageStale === true,
                statusKnown: item.statusKnown === true,
                statusActive: item.hasIncident === true
                    && String(item.statusSeverity || "").length > 0
                    && String(item.status || "").length > 0,
                statusSeverity: String(item.statusSeverity || ""),
                statusIncidentKey: String(item.statusIncidentKey || ""),
                rows: rows
            })
        }
        return result
    }

    function notificationPlannerOptions(mode) {
        return {
            mode: mode,
            statusEnabled: includeStatus && notifyStatusIncidents,
            quotaEnabled: notifyQuotaWarnings,
            paceEnabled: notifyPredictivePaceWarnings,
            resetEnabled: notifyLimitResets,
            resetArmThreshold: limitResetArmThreshold,
            resetFloor: limitResetFloor
        }
    }

    function dispatchNotificationIntents(intents, observations) {
        for (var i = 0; i < intents.length; i++) {
            var intent = intents[i]
            var observation = observations[intent.observationIndex]
            var item = observation ? providers[observation.providerIndex] : null
            if (!item) continue
            var rows = Array.isArray(item.rows) ? item.rows : []
            var row = rows[intent.rowIndex]
            var resetLine = row && intent.kind === "quota" ? resetLabel(usageResetText(row)) : ""
            var paceEta = row && intent.kind === "pace" ? paceEtaText(row.paceEtaSeconds) : ""
            var message = providerNotificationText.message(intent, item, row, resetLine, paceEta)
            if (message) sendPlasmaNotification(message.title, message.body, message.urgency)
        }
    }

    function processNotifications() {
        if (!enableNotifications || providers.length === 0) {
            return
        }
        var observations = notificationObservations()
        var mode = notificationsPrimed ? "observe" : "prime"
        var result = NotificationPlanner.transition(
            observations,
            notificationMemo,
            notificationPlannerOptions(mode))
        // Commit the full transition before running any external effect. A
        // re-entrant refresh cannot observe the old baseline and notify twice.
        notificationMemo = result.nextMemo
        notificationsPrimed = true
        dispatchNotificationIntents(result.intents, observations)
    }

    function sendPlasmaNotification(title, body, urgency, actionLabel) {
        return notificationDispatcher.send(title, body, urgency, actionLabel)
    }

    Controllers.NotificationDispatcher {
        id: notificationDispatcher
    }

    function planText(providerID, method) {
        if (providerKey(providerID) === "codex" && method.length > 0) {
            return capitalize(method)
        }
        return ""
    }

    function providerKey(value) {
        return ProviderIdentity.resolveProviderKey(value)
    }

    function providerCliArgument(value) {
        return ProviderIdentity.providerCliArgument(value)
    }

    function providerDisplayTitle(value) {
        return providerTitle(value, "", privacyMode)
    }

    function providerTitle(value, displayName, privateTitle) {
        var key = providerKey(value)
        // Optional display names are CLI-controlled and may carry structured
        // values: their primitive conversion throws and would discard the
        // whole provider snapshot. Only truthy scalars reach String();
        // anything else degrades to the bundled fallback, keeping the quota.
        var rawDisplay = displayName || ""
        if (typeof rawDisplay !== "string" && typeof rawDisplay !== "number" && typeof rawDisplay !== "boolean") {
            rawDisplay = ""
        }
        var override = privateTitle === true ? "" : ProviderIdentity.providerTitleOverride(key)
        if (override.length > 0) {
            return override
        }
        var preferred = privateTitle === true ? "" : String(rawDisplay).trim()
        if (preferred.length > 0) {
            return preferred
        }
        return providerNames.titleForKey(key, privateTitle === true ? i18n("Provider") : "")
    }

    function providerIconSource(value) {
        var fileName = ProviderIdentity.providerIconFileName(value)
        if (fileName.length === 0) {
            return "view-statistics"
        }
        return Qt.resolvedUrl("../icons/providers/" + fileName)
    }

    function providerIconIsMask(value) {
        return true
    }

    // Whether the rendered icon can stand in for the provider's name. Bundled
    // icons and brand colors cover the same providers, so a provider outside
    // that set falls back to one generic icon in the theme highlight and is
    // indistinguishable from every other provider outside it.
    function providerIconIdentifies(value) {
        return ProviderIdentity.providerBrandColorChannels(value).length === 3
    }

    function providerColor(value) {
        var channels = ProviderIdentity.providerBrandColorChannels(value)
        if (channels.length !== 3) {
            return Kirigami.Theme.highlightColor
        }
        return Qt.rgba(channels[0], channels[1], channels[2], 1)
    }

    function providerDashboardUrl(providerID) {
        return ProviderIdentity.providerDashboardUrl(providerID)
    }

    function providerDocsUrl(providerID) {
        return ProviderIdentity.providerDocsUrl(providerID)
    }

    function providerLoginUrl(providerID) {
        return ProviderIdentity.providerLoginUrl(providerID)
    }

    function providerAccountUrl(providerID) {
        var url = providerLoginUrl(providerID)
        return url.length > 0 ? url : providerDashboardUrl(providerID)
    }

    function providerStatusUrl(providerID) {
        return ProviderIdentity.providerStatusUrl(providerID)
    }

    function safeStatusUrl(providerID, url) {
        return Normalizer.safeStatusUrl(providerStatusUrl(providerID), url)
    }

    function actionRows(item) {
        if (!item) {
            return []
        }

        // This menu uses raw provider capabilities and account presence only.
        // Titles are local literals; never render identity or provider prose here.
        var rows = []
        rows.push({ title: i18n("Refresh"), icon: "view-refresh", action: "refresh", enabled: true })
        // Same two entries for every provider as on the Providers page.
        var accountUrl = providerAccountUrl(item.provider)
        rows.push({ title: i18n("Account"), icon: "user-identity", action: "account-url", url: accountUrl, enabled: accountUrl.length > 0 })
        if (ProviderIdentity.providerAccessKind(item.provider) === "subscription") {
            rows.push({ title: i18n("Log in"), icon: "dialog-password", action: "cli-login", url: accountUrl,
                enabled: popupLoginSupported(item.provider) || accountUrl.length > 0 })
        } else {
            rows.push({ title: i18n("API Key"), icon: "dialog-password", action: "provider-settings", enabled: true })
        }
        return rows
    }

    readonly property var popupLoginProviders: ["codex", "claude", "antigravity", "grok", "muse", "pi"]
    property string popupLoginPollingFor: ""
    property string popupLoginOpenedUrl: ""
    readonly property string popupLoginScriptPath: {
        var url = String(Qt.resolvedUrl("../../scripts/provider-login.py"))
        try { return url.indexOf("file:///") === 0 ? decodeURIComponent(url.slice(7)) : "" }
        catch (error) { return "" }
    }

    function popupLoginSupported(providerID) {
        return popupLoginProviders.indexOf(providerKey(providerID)) >= 0
    }

    property int popupLoginNonceSerial: 0
    function popupLoginCommand(action, providerID) {
        popupLoginNonceSerial += 1
        var nonce = "LOGIN_NONCE=" + popupLoginNonceSerial + "_" + Date.now()
        return [nonce, "timeout --kill-after=2s 40s python3", Guards.shellQuote(popupLoginScriptPath), action,
                "--provider", Guards.shellQuote(providerKey(providerID))].join(" ")
    }

    function startPopupLogin(providerID) {
        popupLoginPollingFor = providerKey(providerID)
        popupLoginOpenedUrl = ""
        popupLoginSource.connectSource(popupLoginCommand("start", providerID))
    }

    function acceptPopupLoginStatus(providerID, value) {
        var state = value && typeof value === "object" ? value : { state: "failed" }
        if (state.state === "done") {
            popupLoginPollingFor = ""
            popupLoginOpenedUrl = ""
            popupLoginSource.connectSource(popupLoginCommand("cancel", providerID))
            root.refreshNow(true)
            return
        }
        if (["waiting", "needs_code"].indexOf(state.state) >= 0 && state.url && String(state.url) !== popupLoginOpenedUrl) {
            popupLoginOpenedUrl = String(state.url)
            Qt.openUrlExternally(popupLoginOpenedUrl)
        }
        if (state.state === "needs_code") {
            Plasmoid.configuration.providerSettingsFocus = providerID
            var configure = Plasmoid.internalAction("configure")
            if (configure) configure.trigger()
        }
        if (["failed", "missing", "unsupported", "absent"].indexOf(state.state) >= 0) {
            popupLoginPollingFor = ""
            popupLoginOpenedUrl = ""
        }
    }

    function monthDayTimeText(timestampMs) {
        return timeLabels.monthDayTime(timestampMs)
    }

    function performAction(actionRow) {
        var actionID = actionRow && actionRow.action ? actionRow.action : actionRow
        var item = selectedProviderData
        if (actionID === "account-url" && actionRow && actionRow.url) {
            Qt.openUrlExternally(actionRow.url)
        } else if (actionID === "cli-login" && item) {
            if (popupLoginSupported(item.provider)) {
                startPopupLogin(item.provider)
            } else if (actionRow && actionRow.url) {
                Qt.openUrlExternally(actionRow.url)
            }
        } else if (actionID === "provider-settings" && item) {
            // The login and key flows live on the Providers page; open it on this provider.
            Plasmoid.configuration.providerSettingsFocus = item.provider
            var configure = Plasmoid.internalAction("configure")
            if (configure) configure.trigger()
        } else if (actionID === "refresh") {
            root.refreshNow(true)
        } else if (actionID === "about") {
            Qt.openUrlExternally("https://github.com/steipete/CodexBar")
        } else if (actionID === "settings") {
            var action = Plasmoid.internalAction("configure")
            if (action) {
                action.trigger()
            }
        }
    }

    function withAlpha(color, alpha) {
        return Qt.rgba(color.r, color.g, color.b, alpha)
    }

    function canvasColor(color, alpha) {
        var opacity = alpha === undefined ? color.a : alpha
        return "rgba("
            + Math.round(color.r * 255) + ", "
            + Math.round(color.g * 255) + ", "
            + Math.round(color.b * 255) + ", "
            + opacity + ")"
    }

    function contrastTextColor(color) {
        var luminance = (0.2126 * color.r) + (0.7152 * color.g) + (0.0722 * color.b)
        return luminance > 0.62 ? Qt.rgba(0.08, 0.08, 0.1, 1) : Qt.rgba(1, 1, 1, 1)
    }

    function readableAccentColor(accent, background) {
        var surface = background || Kirigami.Theme.backgroundColor
        return ThemeContrast.readableAccentColor(
            accent,
            surface,
            Kirigami.Theme.textColor)
    }

    function providerReadableColor(value, background) {
        return readableAccentColor(
            providerColor(value),
            background || Kirigami.Theme.backgroundColor)
    }

    function copyObject(item) {
        return Guards.copyObject(item)
    }

    function capitalize(value) {
        var text = String(value || "")
        if (text.length === 0) {
            return ""
        }
        return text.charAt(0).toUpperCase() + text.slice(1)
    }

    // Four- and five-figure totals are unreadable as a bare digit run, and
    // Number.toLocaleString with 'f' localizes the decimal mark without adding
    // group separators, so the grouping is applied here.
    function groupedDecimalString(value, digits) {
        return CostPresentation.groupedDecimalString(costNumberFormat, value, digits)
    }

    function amountString(value, currency) {
        return CostPresentation.amountString(costNumberFormat, value, currency)
    }

    function tokenCountString(tokens) {
        return CostPresentation.tokenCountString(tokens, costNumberFormat)
    }

    function usageCountText(value, unit) {
        return costText.usageCountText(value, unit)
    }

    function switcherCandidateRows(item) {
        return PanelDisplay.candidateRows(item ? item.rows : null,
            item ? providerKey(item.provider) : "",
            item && Normalizer.authoritativeQuota(item) ? item.providerCost : null,
            i18n("Included plan"))
    }

    function panelDisplayRow(item, mode) {
        return PanelDisplay.rowForMode(switcherCandidateRows(item), mode, panelQuotaLane)
    }

    function panelMeterRows(item) {
        return PanelDisplay.meterRows(switcherCandidateRows(item), panelQuotaLane)
    }

    function panelMeterDescription(item) {
        var description = panelMeterRows(item).map(function(row) {
            return root.quotaDescription(row)
        }).join(". ")
        if (!item || item.usageStale !== true) {
            return description
        }
        var lastKnown = lastGoodUsageText(item)
        return description.length > 0 ? i18n("%1 - %2", description, lastKnown) : lastKnown
    }

    function switcherMetricRow(item) {
        // Popup tabs retain their automatic quota independently of panel settings.
        return PanelDisplay.rowForMode(switcherCandidateRows(item), "percent")
    }

    function switcherPercent(item) {
        var row = switcherMetricRow(item)
        return row ? displayPercent(row) : -1
    }

    // Overview rows draw a labelled meter per quota lane, independent of the
    // panel's lane choice.
    function overviewMeterRows(item) {
        return PanelDisplay.overviewMeterRows(switcherCandidateRows(item))
    }

    function quotaDescription(row) {
        var text = i18n("%1: %2", row.label, usagePercentText(row))
        var reset = resetTextForRow(row)
        return reset.length > 0 ? i18n("%1 - %2", text, reset) : text
    }

    // A popup tab shows its quota only as an underline and its failure only
    // by dimming, so screen readers get both as text.
    function switcherDescription(item) {
        if (!item) {
            return ""
        }
        var parts = []
        var row = switcherMetricRow(item)
        if (row && row.hasPercent) {
            parts.push(quotaDescription(row))
        }
        if (item.usageStale === true) {
            parts.push(lastGoodUsageText(item))
        }
        if (item.error && item.error.length > 0) {
            parts.push(item.error)
        }
        return parts.join(". ")
    }

    // Eligibility, the stored selection, and the visible limit all live in
    // OverviewProviders, so the settings checkboxes and the rendered rows
    // resolve the same canonical provider IDs.
    function overviewProviders() {
        return OverviewProviders.visibleItems(providers, overviewProviderIDsRaw)
    }

    function providerIndex(item) {
        return item ? providerIndexForID(item.provider) : -1
    }

    function providerIndexForID(providerID) {
        var id = String(providerID || "")
        if (id.length === 0 || !providers) {
            return -1
        }
        for (var i = 0; i < providers.length; i++) {
            if (providers[i] && providers[i].provider === id) {
                return i
            }
        }
        return -1
    }

    function openProviderFromPanel(providerID) {
        var index = providerIndexForID(providerID)
        if (index < 0) {
            return false
        }
        selectedProviderID = providers[index].provider
        selectionInitialized = true
        expanded = true
        return true
    }

    function providerPlaceholderText(item) {
        return OverviewProviders.placeholderText(item)
    }

    function usagePercentText(row) {
        return usageWindowText.percentText(row, usageBarsShowUsed)
    }

    function usageConfidenceText(row) {
        return usageWindowText.confidenceText(row)
    }

    function displayPercent(row) {
        if (!row || !row.hasPercent) {
            return 0
        }
        return usageBarsShowUsed ? row.usedPercent : row.leftPercent
    }

    function paceMarkerPercent(row) {
        if (!row || row.pacePercent < 0 || !Normalizer.canPresentQuotaDetails(row)) {
            return -1
        }
        return usageBarsShowUsed ? row.pacePercent : clamp(100 - row.pacePercent, 0, 100)
    }

    function percentSuffix() {
        return usageBarsShowUsed ? i18n("used") : i18n("left")
    }

    function resetLabel(value) {
        return usageWindowText.resetLabel(value)
    }

    function providerCountText(count) {
        var total = Math.max(0, Math.round(Number(count) || 0))
        return i18np("%1 provider", "%1 providers", total)
    }

    function clamp(value, minimum, maximum) {
        return Normalizer.clamp(value, minimum, maximum)
    }

    function selectedCompactProvider() {
        if (providers.length === 0) {
            return null
        }
        var panelItems = panelProviderItems()
        var selected = selectedProviderIndex >= 0 ? providers[selectedProviderIndex] : null
        return PopupSelection.compactPanelProvider(
            autoSelectProvider, selected, panelItems,
            autoSelectedProviderIndex(panelItems))
    }

    function globalViewAvailability() {
        return {
            overview: overviewAvailable
        }
    }

    function selectGlobalView(viewID) {
        var candidate = String(viewID || "")
        if (!PopupSelection.globalViewIsAvailable(candidate, globalViewAvailability())) {
            return
        }

        selectedGlobalView = candidate
        selectedProviderID = ""
        selectionInitialized = true
    }

    function updateSelectedProvider() {
        var firstProviderID = providers && providers.length > 0
            ? providers[0].provider
            : ""
        var automaticProviderID = firstProviderID.length > 0
            ? providers[autoSelectedProviderIndex(providers)].provider
            : ""
        var next = PopupSelection.reconcile({
            providerID: selectedProviderID,
            globalView: selectedGlobalView,
            initialized: selectionInitialized
        }, {
            autoSelect: autoSelectProvider,
            currentProviderExists: selectedProviderIndex >= 0,
            firstProviderID: firstProviderID,
            automaticProviderID: automaticProviderID,
            globalViews: globalViewAvailability()
        })
        selectedProviderID = next.providerID
        selectedGlobalView = next.globalView
        selectionInitialized = next.initialized
    }

    function reconcileGlobalViewAvailability() {
        if (PopupSelection.globalSelectionNeedsReconciliation({
            providerID: selectedProviderID,
            globalView: selectedGlobalView,
            initialized: selectionInitialized
        }, globalViewAvailability())) {
            updateSelectedProvider()
        }
    }

    // Usage and incident severity decide the automatic selection in
    // ProviderAutoSelect; the roster it ranks is the panel-filtered list for
    // the panel and the full roster for the popup.
    function autoSelectedProviderIndex(items) {
        return ProviderAutoSelect.bestIndex(Array.isArray(items) ? items : providers)
    }

    // The panel-only provider selection. The popup, notifications, and every
    // other surface keep the full roster; only compact rendering narrows here.
    // Local change: the popup toggles a provider in or out of the panel by
    // clicking its icon. Selecting every provider collapses back to "all".
    function panelShowsProvider(providerID) {
        if (!PanelProviders.selectionActive(panelProviderIDsRaw)) {
            return true
        }
        return PanelProviders.configuredProviderIDs(panelProviderIDsRaw)
            .indexOf(ProviderOrder.normalizedProviderID(providerID)) >= 0
    }

    function togglePanelProvider(providerID) {
        var ordered = providers.map(function(item) { return ProviderOrder.normalizedProviderID(item.provider) })
        var current = PanelProviders.selectionActive(panelProviderIDsRaw)
            ? PanelProviders.configuredProviderIDs(panelProviderIDsRaw) : ordered
        var next = PanelProviders.toggledSelection(ordered, current, providerID, !panelShowsProvider(providerID))
        var all = ordered.length > 0 && ordered.every(function(id) { return next.indexOf(id) >= 0 })
        Plasmoid.configuration.panelProviderIDs = all ? "" : PanelProviders.selectionText(next)
    }

    // Drop target from the compact view: place providerID before beforeProviderID
    // (or last when empty). Writes the shared provider order.
    function reorderPanelProviders(providerID, beforeProviderID) {
        var source = ProviderOrder.normalizedProviderID(providerID)
        var before = ProviderOrder.normalizedProviderID(beforeProviderID || "")
        if (source.length === 0 || source === before) return
        var ids = providers.map(function(item) { return ProviderOrder.normalizedProviderID(item.provider) })
            .filter(function(id) { return id !== source })
        var at = before.length > 0 ? ids.indexOf(before) : -1
        if (at < 0) ids.push(source); else ids.splice(at, 0, source)
        Plasmoid.configuration.providerOrder = ids.join(",")
    }

    function panelProviderItems() {
        return PanelProviders.filteredItems(providers, panelProviderIDsRaw)
    }

    function compactProviders() {
        if (!providers || Plasmoid.configuration.showMultiProviderInPanel === false) {
            return []
        }

        var result = []
        var panelItems = panelProviderItems()
        for (var i = 0; i < panelItems.length && result.length < PanelProviders.maximumSelectableProviders; i++) {
            result.push(providerPresentation(panelItems[i]))
        }
        return result
    }

    // The panel label as separable segments. The compact renderer surrenders
    // whole segments when the meter row leaves it too little room, so it needs
    // them apart; every other caller joins them back through compactText().
    function compactTextSegments() {
        var item = providerPresentation(selectedCompactProvider())
        var row = panelDisplayRow(item, menuBarDisplayMode)
        return panelText.segments(item,
            true,
            PanelProviders.selectionActive(panelProviderIDsRaw),
            item ? menuBarDisplayText(item) : "",
            item ? providerIconIdentifies(item.provider) : false)
    }

    function compactText() {
        return panelText.fullText(compactTextSegments())
    }

    function setHoveredPanelProvider(providerID) {
        hoveredPanelProviderID = String(providerID || "")
    }

    function clearHoveredPanelProvider(providerID) {
        var id = String(providerID || "")
        if (hoveredPanelProviderID === id) {
            hoveredPanelProviderID = ""
        }
    }

    function hoveredPanelProvider() {
        var id = String(hoveredPanelProviderID || "")
        if (id.length === 0 || !providers) {
            return null
        }
        // Visibility rules can filter a hovered meter out of the rendered
        // compactProviders() while its provider stays in providers, and its
        // destroyed MouseArea delivers no reliable hover-exit for cleanup.
        // Narrow the tooltip only while the meter is actually rendered.
        var rendered = compactProviders().some(function(meter) {
            return meter && meter.provider === id
        })
        if (!rendered) {
            return null
        }
        for (var i = 0; i < providers.length; i++) {
            if (providers[i] && providers[i].provider === id) {
                return providers[i]
            }
        }
        return null
    }

    function panelProviderToolTipText(item) {
        var presented = providerPresentation(item)
        return panelText.providerToolTipText(presented, panelMeterDescription(presented))
    }

    function panelToolTipText() {
        var hovered = hoveredPanelProvider()
        var hoveredLine = hovered ? panelProviderToolTipText(hovered) : ""
        if (hoveredLine.length > 0) {
            return hoveredLine
        }
        var lines = []
        var roster = panelProviderItems()
        for (var i = 0; i < roster.length && lines.length < 6; i++) {
            var line = panelProviderToolTipText(roster[i])
            if (line.length > 0) {
                lines.push(line)
            }
        }
        return panelText.toolTipText(lines,
            privateErrorText(Normalizer.boundedDisplayText(errorText, 500)))
    }

    function menuBarDisplayText(item) {
        if (!item) {
            return ""
        }
        var mode = String(menuBarDisplayMode || "percent")
        var row = panelDisplayRow(item, mode)
        return panelText.displayText(row, mode,
            mode === "resetTime" ? resetTextForRow(row) : "",
            mode === "runOut" ? runOutTextForRow(row) : "")
    }

    // Duration-only forecast token. It stays empty unless the CLI actually
    // predicts exhaustion before the reset, so the panel never shows a
    // countdown the pace data does not support.
    // Account options retain their own receipt time across later refreshes.
    function runOutTextForRow(row) {
        if (!PanelDisplay.rowHasRunOut(row)) {
            return ""
        }
        return paceEtaText(PanelDisplay.remainingSeconds(
            row.paceEtaSeconds, row.paceObservedAtMs, panelClockMs))
    }

    function resetTextForRow(row) {
        var reset = usageResetText(row)
        if (reset.length === 0) {
            return ""
        }
        return resetLabel(reset)
    }

    // Credit balances are plain counts, so they share the popup's grouped,
    // locale-aware figure formatting instead of printing a bare digit run with
    // a hardcoded decimal mark. A whole balance keeps no fractional part, so a
    // depleted account reads as "0" rather than "0.0".
    function formatNumber(value) {
        return CostPresentation.formatCount(costNumberFormat, value)
    }

    Timer {
        id: panelClockTimer

        interval: root.panelClockIntervalMs
        repeat: true
        running: root.providers.length > 0
        triggeredOnStart: false
        onTriggered: {
            root.panelClockMs = Date.now()
            root.expireStaleUsage(root.panelClockMs)
        }
    }

    Components.UsageWindowText {
        id: usageWindowText
        dateLabels: timeLabels
    }

    Components.ProviderNotificationText {
        id: providerNotificationText
    }

    Components.PanelText {
        id: panelText

        loading: root.loading
        usageBarsShowUsed: root.usageBarsShowUsed
        // Local change: the logo identifies the provider; name text has no UI.
        showProvider: false
        showPercent: Plasmoid.configuration.showPercentInPanel
        showCredits: Plasmoid.configuration.showCreditsInPanel
        numberFormat: root.costNumberFormat
    }

    Components.CostText {
        id: costText
        numberFormat: root.costNumberFormat
    }

    Components.ProviderCostDetails {
        id: providerCostDetails

        numberFormat: root.costNumberFormat
    }

    Components.ProviderNames {
        id: providerNames
    }

    Components.RateWindowLabels {
        id: rateWindowLabels
    }

    Components.TimeLabels {
        id: timeLabels
    }

    Controllers.ProviderConfigWatcher {
        id: providerConfigWatcher

        active: root.usageLifecycleInitialized
        onStampObserved: function(stamp, initial) {
            root.handleProviderConfigObservation(stamp, initial)
        }
    }

    Controllers.UsageController {
        id: usageController

        commandPath: root.commandPath
        provider: root.provider
        sourceMode: root.source
        includeStatus: root.includeStatus
        selectedAccounts: root.selectedAccounts
        providerConfigRevision: root.providerConfigRevision
        providerConfigStamp: root.providerConfigStamp
        providerOrderRaw: root.providerOrderRaw
        refreshIntervalSec: root.refreshIntervalSec
        refreshOnOpen: root.refreshOnOpen
        popupVisible: root.expanded
        onSnapshotReceived: function(items) {
            root.commitUsageSnapshot(items.map(function(item) { return root.presentProviderSnapshot(item) }))
        }
        onFailed: function(message) { root.failUsageRefresh(message) }
        onEmptyRoster: root.invalidateUsageData()
    }

    Plasma5Support.DataSource {
        id: popupLoginSource
        engine: "executable"
        interval: 0
        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
            var match = /--provider '?([a-z0-9]+)'?/.exec(sourceName)
            var providerID = match ? match[1] : ""
            var text = data && data["stdout"] ? String(data["stdout"]) : ""
            var value = null
            try { value = JSON.parse(text) } catch (error) { value = null }
            if (providerID.length > 0 && sourceName.indexOf(" cancel ") < 0) {
                root.acceptPopupLoginStatus(providerID, value)
            }
        }
    }

    Timer {
        interval: 1500
        repeat: true
        running: root.popupLoginPollingFor.length > 0
        onTriggered: if (root.popupLoginPollingFor.length > 0) {
            popupLoginSource.connectSource(root.popupLoginCommand("status", root.popupLoginPollingFor))
        }
    }

    Controllers.ManagedCliController {
        commandPath: root.commandPath
        automaticUpdates: Plasmoid.configuration.cliAutomaticUpdates === true
        onChanged: root.refreshNow(true)
    }

    compactRepresentation: Components.CompactRepresentation {
        applet: root
        // Record the live panel thickness so the settings preview is true to size.
        readonly property int panelThickness: Math.round(root.verticalFormFactor ? width : height)
        onPanelThicknessChanged: {
            if (panelThickness > 0 && Plasmoid.configuration.panelThickness !== panelThickness) {
                Plasmoid.configuration.panelThickness = panelThickness
            }
        }
    }

    fullRepresentation: Components.FullRepresentation {
        applet: root
    }
}
