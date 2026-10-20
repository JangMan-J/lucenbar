.pragma library
.import "PanelDisplay.js" as PanelDisplay
.import "PanelElements.js" as PanelElements
.import "PanelProviders.js" as PanelProviders
.import "ProviderOrder.js" as ProviderOrder
.import "SafeText.js" as SafeText

var scenarios = ["normal", "nearLimit"];

function quota(lane, usedPercent, pacePercent, resetMinutes, nearLimit, nowMs) {
    return {
        lane: lane,
        hasPercent: true,
        usedPercent: usedPercent,
        leftPercent: 100 - usedPercent,
        pacePercent: pacePercent,
        paceOnTop: !nearLimit,
        paceEtaSeconds: nearLimit ? 1200 : 0,
        resetMinutes: resetMinutes,
        resetsAt: new Date(nowMs + resetMinutes * 60000).toISOString()
    };
}

// Quotas, credits, and incidents are fixed examples, never live observations.
function providersForScenario(value, nowMs) {
    var nearLimit = value === "nearLimit";
    return [
        {
            provider: "codex",
            title: "Codex",
            credits: 125,
            hasIncident: value === "incident",
            statusSeverity: value === "incident" ? "minor" : "",
            rows: [quota("primary", nearLimit ? 98 : 42, 45, nearLimit ? 30 : 180, nearLimit, nowMs), quota("secondary", nearLimit ? 88 : 27, 35, 5760, nearLimit, nowMs), quota("tertiary", nearLimit ? 97 : 33, 40, 720, nearLimit, nowMs)]
        },
        {
            provider: "claude",
            title: "Claude",
            credits: null,
            hasIncident: false,
            statusSeverity: "",
            rows: [quota("primary", nearLimit ? 84 : 58, 60, 120, nearLimit, nowMs), quota("secondary", nearLimit ? 91 : 61, 65, 7200, nearLimit, nowMs)]
        }
    ];
}

function scenarioProviders(scenario, nowMs, roster) {
    var examples = providersForScenario(scenario, nowMs);
    if (!Array.isArray(roster) || roster.length === 0) {
        return examples;
    }
    var providers = [];
    var seen = [];
    for (var i = 0; i < Math.min(roster.length, ProviderOrder.maximumProviderItems); i++) {
        var entry = roster[i];
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
            continue;
        }
        var id = ProviderOrder.normalizedProviderID(entry.provider);
        if (!id || seen.indexOf(id) >= 0) {
            continue;
        }
        seen.push(id);
        var sample = examples[id === "claude" ? 1 : 0];
        var title = SafeText.boundedDisplayText(entry.displayName, 120);
        providers.push({
            provider: id,
            title: title || id,
            credits: id === "codex" ? sample.credits : null,
            hasIncident: sample.hasIncident,
            statusSeverity: sample.statusSeverity,
            rows: sample.rows
        });
    }
    return providers;
}

function model(options, scenarioValue, nowMs) {
    var settings = options || {};
    var scenario = scenarios.indexOf(scenarioValue) >= 0 ? scenarioValue : "normal";
    var clockMs = typeof nowMs === "number" && isFinite(nowMs) && Math.abs(nowMs) < 8000000000000000 ? nowMs : Date.UTC(2026, 0, 1, 12);
    var providers = ProviderOrder.orderedItems(scenarioProviders(scenario, clockMs, settings.providerRoster), settings.providerOrder);
    var panelProviders = PanelProviders.filteredItems(providers, settings.panelProviderFilter);
    var selected = panelProviders.length > 0 ? panelProviders[0] : null;
    if (settings.autoSelectProvider === true) {
        var highestUsage = -1;
        for (var i = 0; i < panelProviders.length; i++) {
            var provider = panelProviders[i];
            var usage = Math.max.apply(null, provider.rows.map(function (row) { return row.usedPercent; }));
            if (usage > highestUsage) {
                highestUsage = usage;
                selected = provider;
            }
        }
    }
    var lane = PanelDisplay.safeLane(settings.quotaLane);
    var mode = PanelDisplay.safeMode(settings.displayMode);
    var textRow = selected ? PanelDisplay.rowForMode(selected.rows, mode, lane) : null;
    return {
        scenario: scenario,
        clockMs: clockMs,
        minimalStyle: false,
        elementOrder: PanelElements.normalizedOrder(settings.elementOrder),
        lane: lane,
        mode: mode,
        providers: providers,
        selectedProvider: selected,
        textRow: textRow,
        textVisible: true,
        meterProviders: settings.showMeters === false ? [] : panelProviders.slice(0, PanelProviders.maximumSelectableProviders),
        incidentProvider: scenario === "incident" ? providers.filter(function (provider) {
            return provider.hasIncident;
        })[0] : null
    };
}
