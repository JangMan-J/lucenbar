import QtQuick
import QtQuick.Window
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.plasmoid
import "components" as Components
import "controllers" as Controllers
import "CommandLedger.js" as CommandLedger
import "Guards.js" as Guards
import "ProviderIdentity.js" as ProviderIdentity
import "ProviderOrder.js" as ProviderOrder
import "SafeText.js" as SafeText
import "ThemeContrast.js" as ThemeContrast
import "config" as ProviderConfig
import "config/ProviderConfigProtocol.js" as ProviderConfigProtocol
import "config/ProviderDescriptor.js" as ProviderDescriptor
import "config/ProviderList.js" as ProviderList
import "config/ProviderOperations.js" as ProviderOperations
import "config/ProviderSource.js" as ProviderSource

KCM.SimpleKCM {
    id: page

    // Read the configured command path so this page can call the same CLI the
    // widget uses. The provider list/toggles below persist immediately through
    // `codexbar config enable/disable`, independent of the KCM Apply cycle.
    property string cfg_commandPath
    // cfg_*Default mirrors the schema default in contents/config/main.xml.
    // Plasma's configuration map also exposes a <key>Default entry, so the
    // config dialog injects cfg_<key>Default over these initializers
    // (plasma-workspace 6.7.4); they stay the portable fallback for loaders that
    // do not, and the restore-defaults action reads them either way.
    // tests/test_ui_settings_pages.py checks them against main.xml for drift.
    property string cfg_commandPathDefault: "codexbar"
    property alias cfg_refreshOnOpen: refreshOnOpenCheck.checked
    property bool cfg_refreshOnOpenDefault: true
    property int cfg_refreshInterval: 300
    property int cfg_refreshIntervalDefault: 300
    property bool cfg_includeStatus: false
    property bool cfg_includeStatusDefault: false
    property bool cfg_cliAutomaticUpdates: false
    property bool cfg_cliAutomaticUpdatesDefault: false

    property bool cfg_usageBarsShowUsed
    property bool cfg_usageBarsShowUsedDefault: false
    property string cfg_providerOrder
    property string cfg_providerOrderDefault: ""
    property bool cfg_showPercentInPanel
    property bool cfg_showPercentInPanelDefault: false
    property bool cfg_showMultiProviderInPanel
    property bool cfg_showMultiProviderInPanelDefault: true
    property bool cfg_showCreditsInPanel
    property bool cfg_showCreditsInPanelDefault: false

    property int cfg_providerConfigRevision
    property int cfg_providerConfigRevisionDefault: 0

    readonly property string commandPath: (cfg_commandPath || "codexbar").trim()

    property var providers: []
    property string filterText: ""
    // Local change: the list defaults to providers the CLI can actually use on
    // this machine (credentials or a tool detected), plus anything enabled.
    property bool showAllProviders: false
    property var detectedProviders: null   // providerID -> bool, null until scanned
    readonly property int detectionCacheMaxAgeMs: 60 * 60 * 1000
    function loadDetectionCache() {
        var raw = cfgValueOrEmpty("providerDetectionCache")
        if (raw.length === 0 || raw.length > 131072) return false
        try {
            var cache = JSON.parse(raw)
            if (!cache || typeof cache !== "object" || typeof cache.detected !== "object") return false
            var clean = ({})
            for (var key in cache.detected) {
                if (hasOwnKey(cache.detected, key) && providerMapKey(key).length > 0) clean[providerMapKey(key)] = cache.detected[key] === true
            }
            detectedProviders = clean
            // Tracking status per provider rides along, re-normalised so only
            // known fields survive.
            if (cache.diagnostics && typeof cache.diagnostics === "object") {
                var restored = copyObject(providerDiagnostics)
                for (var id in cache.diagnostics) {
                    if (hasOwnKey(cache.diagnostics, id) && providerMapKey(id).length > 0 && cache.diagnostics[id] && typeof cache.diagnostics[id] === "object") {
                        restored[providerMapKey(id)] = ProviderConfigProtocol.normalizeProviderDiagnostic(cache.diagnostics[id])
                    }
                }
                providerDiagnostics = restored
            }
            // Fresh only if it also carries per-provider results for all enabled
            // providers; an older or partial cache is shown but triggers a rescan.
            if (!(isFinite(Number(cache.at)) && Date.now() - Number(cache.at) < detectionCacheMaxAgeMs
                    && cache.diagnostics && typeof cache.diagnostics === "object")) {
                return false
            }
            for (var i = 0; i < providers.length; i++) {
                if (providers[i].enabled && !providerDiagnosticFor(providers[i].provider)) {
                    return false
                }
            }
            return true
        } catch (error) {
            return false
        }
    }
    function saveDetectionCache(detected, diagnostics) {
        if (!detected || typeof detected !== "object") return
        // Raw-shaped records (provider/auth/source/error) so the normaliser can re-read them.
        // Only providers that matter (detected, or enabled) keep a record; a
        // disabled, undetected provider reads "Not tracked" without one.
        var compact = ({})
        for (var id in diagnostics) {
            if (!hasOwnKey(diagnostics, id) || !diagnostics[id]) continue
            var item = providerByID(id)
            if (!(detected[id] === true || (item && item.enabled))) continue
            var d = diagnostics[id]
            compact[id] = { provider: d.provider, source: d.source, sourceMode: d.sourceMode,
                auth: { configured: d.authConfigured === true, modes: [] },
                settings: {}, fetchAttempts: [],
                error: d.fetchError ? { safeDescription: d.fetchError } : null }
        }
        try {
            Plasmoid.configuration.providerDetectionCache = JSON.stringify({ at: Date.now(), detected: detected, diagnostics: compact })
            if (typeof Plasmoid.configuration.writeConfig === "function") {
                Plasmoid.configuration.writeConfig()
            }
        } catch (error) {}
    }
    readonly property bool detectionRunning: CommandLedger.hasKind(commands, "diagnoseAll")
    // Detected-only until "Show all" is ticked. Before the scan reports, that
    // means enabled providers only; the scan then widens it.
    readonly property string filterScope: showAllProviders ? "all" : "detected"
    property bool loading: false
    property string errorText: ""
    property string statusText: ""
    property bool providerDescriptorsUnavailable: false
    property bool fireworksSingleKeySetupSupported: false
    property bool munitoApiKeySetupSupported: false
    property bool commandCodeFalApiKeySetupSupported: false
    property bool providerSourceSetupSupported: false
    property var operationState: ProviderOperations.initialState()
    // running command source -> descriptor { kind, provider, desiredEnabled, fieldID, actionID }
    property var commands: ({})
    property int commandRunSerial: 0
    readonly property int configCommandTimeoutMs: 60000
    // Shell-side bound for provider diagnostics, as on the Diagnostics page:
    // 50s plus 5s kill grace stays below configCommandTimeoutMs, so a hung
    // fetch cannot outlive the dialog after the QML deadline retires it.
    readonly property int providerDiagnosticTimeoutSeconds: 50
    readonly property int providerDiagnosticKillAfterSeconds: 5
    readonly property int configSecretCommandTimeoutSeconds: 60
    readonly property int configSecretCommandKillAfterSeconds: 5
    // Bound kdialog itself because disconnecting its shell can orphan it.
    // Keep a long input window separate from the short CLI timeout.
    readonly property int configSecretPromptDialogTimeoutSeconds: 870
    readonly property int configSecretPromptDialogKillAfterSeconds: 5
    // A late submission still gets the full CLI timeout and kill grace.
    // Allow five seconds for startup and result delivery before disconnecting.
    readonly property int configSecretPromptTimeoutMs:
        (configSecretPromptDialogTimeoutSeconds + configSecretPromptDialogKillAfterSeconds
         + configSecretCommandTimeoutSeconds + configSecretCommandKillAfterSeconds) * 1000 + 5000
    // Mirrors the popup de-emphasis step in main.qml. 0.7 is the lowest value
    // where Kirigami.Theme.textColor still clears WCAG AA 4.5:1 on Breeze Light.
    readonly property real secondaryTextOpacity: 0.7
    property var providerDiagnostics: ({})
    property var providerDiagnosticErrors: ({})
    property string selectedProviderID: ""
    property var providerListFocus: null

    readonly property var visibleProviders: ProviderList.filteredProviders(providers, filterText, filterScope, detectedProviders)
    readonly property var providerSettingsGroups: ProviderOrder.settingsGroups(
        visibleProviders, cfg_providerOrder)
    readonly property var visibleEnabledProviders: providerSettingsGroups.enabled
    readonly property var visibleDisabledProviders: providerSettingsGroups.disabled
    readonly property int enabledCount: ProviderList.filteredProviders(providers, "", "enabled").length
    readonly property var selectedProvider: providerByID(selectedProviderID)

    // Qt.callLater coalesces this with the reload the cfg_commandPathChanged
    // handler queues when Plasma injects the stored command path during page
    // creation, so opening the page spawns one CLI list command, not two.
    Component.onCompleted: Qt.callLater(reload)
    onCfg_commandPathChanged: handleCommandPathChanged()

    function handleCommandPathChanged() {
        retireAllConfigCommands()
        providers = []
        providerDiagnostics = ({})
        providerDiagnosticErrors = ({})
        selectedProviderID = ""
        providerDescriptorsUnavailable = false
        fireworksSingleKeySetupSupported = false
        munitoApiKeySetupSupported = false
        commandCodeFalApiKeySetupSupported = false
        providerSourceSetupSupported = false
        Qt.callLater(reload)
    }

    function reload(preserveMessages, retainedErrorText) {
        var decision = ProviderOperations.reloadRequested(operationState,
            CommandLedger.hasKind(commands, "setSource"), preserveMessages, retainedErrorText)
        operationState = decision.state
        if (!decision.reload) {
            return
        }
        disconnectCommandsByKind("list")
        disconnectCommandsByKind("version")
        if (commandPath.length === 0) {
            errorText = i18n("No CLI selected. Install one in General.")
            providers = []
            loading = false
            return
        }
        loading = true
        errorText = decision.retainedErrorText
        if (!decision.preserveMessages) {
            statusText = ""
        }
        loadDetectionCache()
        runProviderListCommand(false, errorText)
        runCliVersionCommand()
    }

    function boundedCliMessage(value) {
        return SafeText.cliMessage(SafeText.stripLoaderDiagnostics(value), SafeText.maximumCliMessageLength)
    }

    // Localizes the classified command result. The precedence decision itself
    // lives in ProviderConfigProtocol.response; only the words live here.
    function providerCommandFailureText(result, context) {
        // A process without an exit status explains no more than missing data.
        if (result.outcome === "exitCodeError" && isFinite(result.exitCode)) {
            return i18n("codexbar exited with code %1", Number(result.exitCode))
        }
        switch (result.outcome) {
        case "tooLarge":
            return i18n("codexbar response exceeded the supported size.")
        case "invalidJson":
            if (context === "list") {
                return i18n("Could not parse codexbar provider JSON: %1", result.message)
            }
            if (context === "diagnostic") {
                return i18n("Could not parse codexbar diagnostics: %1", result.message)
            }
            return i18n("Could not parse codexbar response: %1", result.message)
        case "stderrError":
            return result.message
        case "envelopeError":
        case "statusError":
            return result.message.length > 0
                ? result.message
                : i18n("codexbar command failed.")
        case "timeout":
            return i18n("codexbar command timed out. Try again.")
        default:
            if (context === "diagnostic" && (result.outcome === "empty" || result.outcome === "invalidPayload")) {
                return i18n("codexbar did not return diagnostics.")
            }
            if (context === "command") {
                return i18n("codexbar did not return command data.")
            }
            return i18n("codexbar did not return provider data.")
        }
    }

    // retainedErrorText is an earlier write's error that a successful roster
    // refresh must leave visible instead of clearing.
    function runProviderListCommand(includeDescriptors, retainedErrorText) {
        var command = [
            shellQuote(commandPath),
            "config",
            "providers"
        ]
        if (includeDescriptors) {
            command.push("--descriptors")
        }
        command.push("--format")
        command.push("json")
        command.push("--json-only")
        runCommand(command.join(" "), {
            kind: "list",
            includeDescriptors: includeDescriptors === true,
            retainedErrorText: retainedErrorText ? String(retainedErrorText) : "",
            providerConfigRevision: providerConfigRevisionValue(),
            timeoutMs: configCommandTimeoutMs
        })
    }

    function runCliVersionCommand() {
        runCommand([shellQuote(commandPath), "--version"].join(" "), {
            kind: "version",
            timeoutMs: configCommandTimeoutMs
        })
    }

    function setEnabled(providerID, desiredEnabled) {
        if (commandPath.length === 0 || isPending(providerID)) {
            return
        }
        errorText = ""
        statusText = ""
        markPending(providerID, true, desiredEnabled)
        var cliProviderID = providerCliArgument(providerID)
        var command = [
            shellQuote(commandPath),
            "config",
            desiredEnabled ? "enable" : "disable",
            "--provider",
            shellQuote(cliProviderID),
            "--format",
            "json",
            "--json-only"
        ].join(" ")
        runCommand(command, {
            kind: "toggle",
            provider: providerID,
            desiredEnabled: desiredEnabled,
            timeoutMs: configCommandTimeoutMs
        })
    }

    function setApiKey(providerID) {
        if (commandPath.length === 0 || isPending(providerID)) {
            return
        }
        errorText = ""
        statusText = ""
        var item = providerByID(providerID)
        markPending(providerID, true, item ? item.enabled : false)
        var cliProviderID = providerCliArgument(providerID)

        var prompt = i18n("API key for %1", displayNameForProvider(providerID))
        var script = [
            "if ! command -v kdialog >/dev/null 2>&1; then printf '%s\\n' '{\"error\":{\"message\":\"kdialog is required to prompt for API keys.\"}}'; exit 1; fi",
            "if ! command -v timeout >/dev/null 2>&1 || ! timeout --kill-after=1s 1s true >/dev/null 2>&1; then printf '%s\\n' '{\"error\":{\"message\":\"GNU timeout is required to save API keys safely.\"}}'; exit 1; fi",
            "key=$(timeout --kill-after=\"${7}s\" \"${6}s\" kdialog --password \"$1\" 2>/dev/null)",
            "status=$?",
            "if [ \"$status\" -ne 0 ] || [ -z \"$key\" ]; then printf '%s\\n' '{\"cancelled\":true}'; exit 0; fi",
            "printf '%s' \"$key\" | timeout --kill-after=\"${5}s\" \"${4}s\" \"$2\" config set-api-key --provider \"$3\" --stdin --format json --json-only"
        ].join("; ")
        var command = [
            "sh", "-c", shellQuote(script), "_", shellQuote(prompt),
            shellQuote(commandPath), shellQuote(cliProviderID),
            shellQuote(configSecretCommandTimeoutSeconds),
            shellQuote(configSecretCommandKillAfterSeconds),
            shellQuote(configSecretPromptDialogTimeoutSeconds),
            shellQuote(configSecretPromptDialogKillAfterSeconds)
        ].join(" ")
        runCommand(command, {
            kind: "setApiKey",
            provider: providerID,
            timeoutMs: configSecretPromptTimeoutMs
        })
    }

    function setProviderSource(providerID, mode) {
        if (loading || !providerSourceSetupSupported || !providerByID(providerID) || isPending(providerID)
                || hasPendingFields(providerID)) {
            return
        }
        var plan = ProviderSource.planWrite(commandPath, providerCliArgument(providerID), mode)
        if (!plan.ok) {
            return
        }
        // A diagnostic started before this write can describe the old source.
        retireProviderDiagnostic(providerID)
        errorText = ""
        statusText = ""
        markPending(providerID, true, providerByID(providerID).enabled)
        runCommand(plan.commandLine, {
            kind: "setSource",
            provider: providerID,
            sourceMode: mode,
            timeoutMs: configCommandTimeoutMs
        })
    }

    function loadProviderSettings(providerID) {
        if (commandPath.length === 0 || providerID.length === 0 || isPending(providerID)
                || providerDiagnosticLoadingFor(providerID)) {
            return
        }
        setProviderDiagnosticLoading(providerID, true)
        setProviderDiagnosticError(providerID, "")
        var cliProviderID = providerCliArgument(providerID)
        var command = Guards.boundedShellCommand([
            shellQuote(commandPath),
            "diagnose --provider",
            shellQuote(cliProviderID),
            "--format json --redact"
        ].join(" "), providerDiagnosticTimeoutSeconds, providerDiagnosticKillAfterSeconds)
        runCommand(command, {
            kind: "diagnose",
            provider: providerID,
            timeoutMs: configCommandTimeoutMs
        })
    }

    function scanDetectedProviders() {
        if (commandPath.length === 0 || detectionRunning) {
            return
        }
        // Background work: yield CPU to whatever the user is doing.
        var command = Guards.boundedShellCommand([
            "nice -n 10",
            shellQuote(commandPath),
            "diagnose --provider all --format json --redact"
        ].join(" "), providerDiagnosticTimeoutSeconds, providerDiagnosticKillAfterSeconds)
        runCommand(command, {
            kind: "diagnoseAll",
            provider: "",
            timeoutMs: configCommandTimeoutMs
        })
    }

    function handleDiagnoseAllResult(descriptor, stdoutText, stderrText, exitCode) {
        var parsed = ProviderConfigProtocol.parsedResponse(stdoutText)
        var report = parsed.outcome === "success" && parsed.value && !Array.isArray(parsed.value)
            ? parsed.value.diagnostics : null
        if (!Array.isArray(report)) {
            detectedProviders = ({})
            return
        }
        var detected = ({})
        var diagnostics = copyObject(providerDiagnostics)
        for (var i = 0; i < Math.min(report.length, ProviderOrder.maximumProviderItems); i++) {
            var item = ProviderConfigProtocol.normalizeProviderDiagnostic(report[i])
            var key = providerMapKey(item.provider)
            if (key.length === 0) {
                continue
            }
            detected[key] = item.authConfigured
            diagnostics[key] = item
        }
        providerDiagnostics = diagnostics
        detectedProviders = detected
        saveDetectionCache(detected, diagnostics)
    }

    function disconnectCommandsByKind(kind) {
        var sourceNames = CommandLedger.sourcesOfKind(commands, kind)
        var remaining = commands
        for (var i = 0; i < sourceNames.length; i++) {
            var sourceName = sourceNames[i]
            configSource.disconnectSource(sourceName)
            remaining = CommandLedger.closed(remaining, sourceName)
        }
        commands = remaining
    }

    function retireAllConfigCommands() {
        for (var sourceName in commands) {
            if (hasOwnKey(commands, sourceName)) {
                configSource.disconnectSource(sourceName)
            }
        }
        commands = ({})
        operationState = ProviderOperations.initialState()
        loading = false
    }

    function runReloadDeferredBySourceWrite() {
        var decision = ProviderOperations.deferredReload(operationState,
            CommandLedger.hasKind(commands, "setSource"), errorText)
        operationState = decision.state
        if (decision.reload) {
            reload(decision.preserveMessages, decision.retainedErrorText)
        }
    }

    function runCommand(command, descriptor) {
        commandRunSerial += 1
        var sourceName = CommandLedger.withRunNonce(command, commandRunSerial, Date.now() + "-" + Math.random())
        var nextDescriptor = copyObject(descriptor)
        nextDescriptor.commandPathSignature = commandPath
        // Fail closed like CommandLedger.descriptor: an entry without a usable
        // deadline is skipped by hasTimedConfigCommands and expireConfigCommands,
        // so it would hold its provider's pending state until the page reopens.
        var timeoutMs = Number(nextDescriptor.timeoutMs)
        if (!isFinite(timeoutMs) || timeoutMs <= 0) {
            timeoutMs = configCommandTimeoutMs
        }
        nextDescriptor.deadlineMs = Date.now() + timeoutMs
        commands = CommandLedger.opened(commands, sourceName, nextDescriptor)
        configSource.connectSource(sourceName)
    }

    function hasTimedConfigCommands() {
        return CommandLedger.hasDeadlines(commands)
    }

    function expireConfigCommands(nowMs) {
        var expired = CommandLedger.expired(commands, nowMs)
        if (expired.length === 0) {
            return
        }
        var remaining = commands
        for (var i = 0; i < expired.length; i++) {
            var sourceName = expired[i].sourceName
            configSource.disconnectSource(sourceName)
            remaining = CommandLedger.closed(remaining, sourceName)
        }
        commands = remaining
        for (var j = 0; j < expired.length; j++) {
            var descriptor = expired[j].descriptor
            handleConfigCommandTimeout(descriptor)
        }
    }

    function handleConfigCommandTimeout(descriptor) {
        if (descriptor.kind === "list") {
            loading = false
            errorText = i18n("Loading providers timed out. Try again.")
        } else if (descriptor.kind === "version") {
            fireworksSingleKeySetupSupported = false
            munitoApiKeySetupSupported = false
            commandCodeFalApiKeySetupSupported = false
            providerSourceSetupSupported = false
        } else if (descriptor.kind === "diagnose") {
            setProviderDiagnosticLoading(descriptor.provider, false)
            setProviderDiagnosticError(descriptor.provider, i18n("Loading provider diagnostics timed out. Try again."))
        } else if (descriptor.kind === "toggle") {
            markPending(descriptor.provider, false)
            errorText = i18n("%1 command timed out. Try again.", displayNameForProvider(descriptor.provider))
        } else if (descriptor.kind === "setApiKey" || descriptor.kind === "setSource") {
            markPending(descriptor.provider, false)
            errorText = i18n("%1 command timed out. Try again.", displayNameForProvider(descriptor.provider))
            if (descriptor.kind === "setSource") {
                runReloadDeferredBySourceWrite()
            }
        } else if (descriptor.kind === "descriptorField" || descriptor.kind === "descriptorAction") {
            var fieldID = descriptor.kind === "descriptorField" ? descriptor.fieldID : descriptor.actionID
            markFieldPending(descriptor.provider, fieldID, false)
            errorText = i18n("%1 command timed out. Try again.", displayNameForProvider(descriptor.provider))
        }
    }

    function handleData(sourceName, stdoutText, stderrText, exitCode) {
        var descriptor = CommandLedger.find(commands, sourceName)
        if (!descriptor) {
            return
        }
        commands = CommandLedger.closed(commands, sourceName)
        if (descriptor.commandPathSignature !== commandPath) {
            return
        }

        if (descriptor.kind === "list") {
            handleListResult(descriptor, stdoutText, stderrText, exitCode)
        } else if (descriptor.kind === "version") {
            handleCliVersionResult(stdoutText, exitCode)
        } else if (descriptor.kind === "toggle") {
            handleToggleResult(descriptor, stdoutText, stderrText, exitCode)
        } else if (descriptor.kind === "setApiKey") {
            handleSetApiKeyResult(descriptor, stdoutText, stderrText, exitCode)
        } else if (descriptor.kind === "setSource") {
            handleSetSourceResult(descriptor, stdoutText, stderrText, exitCode)
        } else if (descriptor.kind === "descriptorField") {
            handleDescriptorFieldResult(descriptor, stdoutText, stderrText, exitCode)
        } else if (descriptor.kind === "descriptorAction") {
            handleDescriptorActionResult(descriptor, stdoutText, stderrText, exitCode)
        } else if (descriptor.kind === "diagnose") {
            handleDiagnoseResult(descriptor, stdoutText, stderrText, exitCode)
        } else if (descriptor.kind === "diagnoseAll") {
            handleDiagnoseAllResult(descriptor, stdoutText, stderrText, exitCode)
        }
    }

    function handleCliVersionResult(stdoutText, exitCode) {
        fireworksSingleKeySetupSupported = Number(exitCode) === 0
            && ProviderConfigProtocol.cliVersionAtLeast(stdoutText, 0, 54, 0)
        munitoApiKeySetupSupported = Number(exitCode) === 0
            && ProviderConfigProtocol.cliVersionAtLeast(stdoutText, 0, 77, 0)
        commandCodeFalApiKeySetupSupported = Number(exitCode) === 0
            && ProviderConfigProtocol.cliVersionAtLeast(stdoutText, 0, 75, 0)
        providerSourceSetupSupported = Number(exitCode) === 0
            && ProviderConfigProtocol.cliVersionAtLeast(stdoutText, 0, 73, 0)
    }

    function handleSetSourceResult(descriptor, stdoutText, stderrText, exitCode) {
        applySetSourceResult(descriptor, stdoutText, stderrText, exitCode)
        runReloadDeferredBySourceWrite()
    }

    function applySetSourceResult(descriptor, stdoutText, stderrText, exitCode) {
        markPending(descriptor.provider, false)
        var result = ProviderConfigProtocol.response(stdoutText, stderrText, exitCode, "command")
        if (result.outcome === "cancelled") {
            return
        }
        if (result.outcome !== "success") {
            errorText = i18n("%1: %2", displayNameForProvider(descriptor.provider),
                providerCommandFailureText(result, "command"))
            return
        }
        if (!ProviderSource.resultMatches(result.value,
                providerCliArgument(descriptor.provider), descriptor.sourceMode)) {
            errorText = i18n("codexbar did not return command data.")
            return
        }
        updateProviderEnabled(descriptor.provider, result.value.enabled)
        invalidateProviderDiagnostic(descriptor.provider)
        bumpProviderConfigRevision()
        errorText = ""
        statusText = i18n("%1 setting saved", displayNameForProvider(descriptor.provider))
    }

    function handleListResult(descriptor, stdoutText, stderrText, exitCode) {
        if (!ProviderConfigProtocol.providerListResultIsCurrent(
                descriptor, providerConfigRevisionValue())) {
            reload(true, descriptor.retainedErrorText)
            return
        }
        if (descriptor.includeDescriptors === true && shouldRetryProviderListWithoutDescriptors(stdoutText, stderrText)) {
            providerDescriptorsUnavailable = true
            runProviderListCommand(false, descriptor.retainedErrorText)
            return
        }
        loading = false
        var result = ProviderConfigProtocol.response(stdoutText, stderrText, exitCode, "list", function(identifier) {
            return page.providerTitle(identifier)
        })
        if (result.outcome !== "success") {
            errorText = providerCommandFailureText(result, "list")
            return
        }
        var next = result.value
        // Populate cached detection/diagnostics before setting providers and
        // selectedProviderID so bindings never evaluate against an empty map.
        loadDetectionCache()
        providers = next
        var focus = cfgValueOrEmpty("providerSettingsFocus")
        if (focus.length > 0 && providerByID(focus)) {
            selectedProviderID = focus
            Plasmoid.configuration.providerSettingsFocus = ""
        } else if (!providerByID(selectedProviderID)) {
            selectedProviderID = visibleEnabledProviders.length > 0
                ? visibleEnabledProviders[0].provider
                : (visibleProviders.length > 0 ? visibleProviders[0].provider : firstSelectableProvider(next))
        }
        // The cache shows at once whatever its age. If it is stale or absent,
        // a low-priority rescan runs once the page has settled.
        if (!loadDetectionCache()) {
            detectionRescan.restart()
        }
        if (selectedProvider && selectedProvider.enabled && !providerDiagnosticFor(selectedProviderID)) {
            loadProviderSettings(selectedProviderID)
        }
        if (descriptor.includeDescriptors === true) {
            providerDescriptorsUnavailable = !ProviderConfigProtocol
                .providerListHasSupportedDescriptors(next)
        }
        // reload() already restored the retained error; anything newer came from
        // a write that failed while this list was in flight.
    }

    function shouldRetryProviderListWithoutDescriptors(stdoutText, stderrText) {
        return descriptorListUnsupportedMessage(stdoutText, stderrText).length > 0
    }

    function descriptorListUnsupportedMessage(stdoutText, stderrText) {
        return ProviderConfigProtocol.descriptorUnsupportedMessage(stdoutText, stderrText)
    }

    function handleToggleResult(descriptor, stdoutText, stderrText, exitCode) {
        var result = ProviderConfigProtocol.response(stdoutText, stderrText, exitCode, "command")
        if (result.outcome !== "success") {
            markPending(descriptor.provider, false)
            errorText = result.outcome === "invalidJson"
                ? providerCommandFailureText(result, "command")
                : i18n("%1: %2", displayNameForProvider(descriptor.provider), providerCommandFailureText(result, "command"))
            return
        }
        var payload = result.value
        // Trust the enabled value the CLI reports back; fall back to desired.
        var newEnabled = descriptor.desiredEnabled
        if (payload && !Array.isArray(payload) && payload.enabled !== undefined) {
            newEnabled = payload.enabled === true
        }
        updateProviderEnabled(descriptor.provider, newEnabled)
        markPending(descriptor.provider, false)
        if (newEnabled && !providerDiagnosticFor(descriptor.provider)) {
            loadProviderSettings(descriptor.provider)
        } else if (detectedProviders) {
            saveDetectionCache(detectedProviders, providerDiagnostics)
        }
        bumpProviderConfigRevision()
        errorText = ""
        statusText = i18n("%1 saved", displayNameForProvider(descriptor.provider))
    }

    function handleSetApiKeyResult(descriptor, stdoutText, stderrText, exitCode) {
        markPending(descriptor.provider, false)
        var result = ProviderConfigProtocol.response(stdoutText, stderrText, exitCode, "setApiKey")
        if (result.outcome === "cancelled") {
            statusText = ""
            errorText = ""
            return
        }
        if (result.outcome !== "success") {
            errorText = result.outcome === "invalidJson"
                ? providerCommandFailureText(result, "command")
                : i18n("%1: %2", displayNameForProvider(descriptor.provider), providerCommandFailureText(result, "command"))
            return
        }
        var payload = result.value
        if (payload && !Array.isArray(payload) && payload.enabled !== undefined) {
            updateProviderEnabled(descriptor.provider, payload.enabled === true)
        } else {
            updateProviderEnabled(descriptor.provider, true)
        }
        invalidateProviderDiagnostic(descriptor.provider)
        loadProviderSettings(descriptor.provider)
        bumpProviderConfigRevision()
        errorText = ""
        statusText = i18n("%1 API key saved", displayNameForProvider(descriptor.provider))
    }

    function handleDescriptorFieldResult(descriptor, stdoutText, stderrText, exitCode) {
        markFieldPending(descriptor.provider, descriptor.fieldID, false)
        var result = ProviderConfigProtocol.response(stdoutText, stderrText, exitCode, "command")
        if (result.outcome === "cancelled") {
            return
        }
        if (result.outcome !== "success") {
            errorText = i18n("%1: %2", displayNameForProvider(descriptor.provider),
                providerCommandFailureText(result, "command"))
            return
        }
        if (result.value && !Array.isArray(result.value) && result.value.enabled !== undefined) {
            updateProviderEnabled(descriptor.provider, result.value.enabled === true)
        }
        invalidateProviderDiagnostic(descriptor.provider)
        bumpProviderConfigRevision()
        errorText = ""
        statusText = i18n("%1 setting saved", displayNameForProvider(descriptor.provider))
        page.reload(true)
    }

    function handleDescriptorActionResult(descriptor, stdoutText, stderrText, exitCode) {
        markFieldPending(descriptor.provider, descriptor.actionID, false)
        var result = ProviderConfigProtocol.response(stdoutText, stderrText, exitCode, "command")
        if (result.outcome === "cancelled") {
            return
        }
        if (result.outcome !== "success") {
            errorText = i18n("%1: %2", displayNameForProvider(descriptor.provider),
                providerCommandFailureText(result, "command"))
            return
        }
        if (result.value && !Array.isArray(result.value) && result.value.url) {
            var url = String(result.value.url).trim()
            var safeUrl = ProviderDescriptor.safeHttpsUrl(url)
            if (safeUrl.length > 0) {
                Qt.openUrlExternally(safeUrl)
            } else {
                errorText = i18n("%1 returned an unsupported URL.", displayNameForProvider(descriptor.provider))
                return
            }
        }
        invalidateProviderDiagnostic(descriptor.provider)
        bumpProviderConfigRevision()
        errorText = ""
        statusText = i18n("%1 action completed", displayNameForProvider(descriptor.provider))
        page.reload(true)
    }

    function retireProviderDiagnostic(providerID) {
        for (var sourceName in commands) {
            if (hasOwnKey(commands, sourceName) && commands[sourceName].kind === "diagnose"
                    && commands[sourceName].provider === providerID) {
                configSource.disconnectSource(sourceName)
                commands = CommandLedger.closed(commands, sourceName)
            }
        }
        setProviderDiagnosticLoading(providerID, false)
    }

    function invalidateProviderDiagnostic(providerID) {
        retireProviderDiagnostic(providerID)
        setProviderDiagnostic(providerID, null)
        setProviderDiagnosticError(providerID, "")
    }

    function handleDiagnoseResult(descriptor, stdoutText, stderrText, exitCode) {
        setProviderDiagnosticLoading(descriptor.provider, false)
        var result = ProviderConfigProtocol.response(stdoutText, stderrText, exitCode, "diagnostic")
        if (result.outcome !== "success") {
            setProviderDiagnosticError(descriptor.provider, providerCommandFailureText(result, "diagnostic"))
            return
        }

        setProviderDiagnostic(descriptor.provider, result.value)
        setProviderDiagnosticError(descriptor.provider, "")
        var key = providerMapKey(descriptor.provider)
        if (key.length > 0 && detectedProviders) {
            var nextDetected = copyObject(detectedProviders)
            nextDetected[key] = result.value.authConfigured === true
            detectedProviders = nextDetected
            saveDetectionCache(nextDetected, providerDiagnostics)
        }
    }

    function firstSelectableProvider(list) {
        if (!list || list.length === 0) {
            return ""
        }
        for (var i = 0; i < list.length; i++) {
            if (list[i].enabled) {
                return list[i].provider
            }
        }
        return list[0].provider
    }

    function providerByID(providerID) {
        if (!providerID || providerID.length === 0) {
            return null
        }
        for (var i = 0; i < providers.length; i++) {
            if (providers[i].provider === providerID) {
                return providers[i]
            }
        }
        return null
    }

    function providerDiagnosticFor(providerID) {
        var key = providerMapKey(providerID)
        return key.length > 0 && hasOwnKey(providerDiagnostics, key) ? providerDiagnostics[key] : null
    }

    function setProviderDiagnostic(providerID, diagnostic) {
        var key = providerMapKey(providerID)
        if (key.length === 0) {
            return
        }
        var next = copyObject(providerDiagnostics)
        next[key] = diagnostic
        providerDiagnostics = next
    }

    function providerDiagnosticErrorFor(providerID) {
        var key = providerMapKey(providerID)
        return key.length > 0 && hasOwnKey(providerDiagnosticErrors, key) ? providerDiagnosticErrors[key] : ""
    }

    function setProviderDiagnosticError(providerID, message) {
        var key = providerMapKey(providerID)
        if (key.length === 0) {
            return
        }
        var next = copyObject(providerDiagnosticErrors)
        var cleanMessage = boundedCliMessage(message)
        if (cleanMessage.length > 0) {
            next[key] = cleanMessage
        } else {
            delete next[key]
        }
        providerDiagnosticErrors = next
    }

    function providerDiagnosticLoadingFor(providerID) {
        return ProviderOperations.isDiagnosticPending(operationState, providerMapKey(providerID))
    }

    function setProviderDiagnosticLoading(providerID, value) {
        operationState = ProviderOperations.diagnosticPendingChanged(
            operationState, providerMapKey(providerID), value)
    }


    function updateProviderEnabled(providerID, enabled) {
        var next = []
        for (var i = 0; i < providers.length; i++) {
            var item = copyObject(providers[i])
            if (item.provider === providerID) {
                item.enabled = enabled
            }
            next.push(item)
        }
        providers = next
    }

    function isPending(providerID) {
        return ProviderOperations.isProviderPending(operationState, providerMapKey(providerID))
    }

    function visualEnabled(providerID, fallback) {
        return ProviderOperations.enabledValue(operationState, providerMapKey(providerID), fallback)
    }

    function markPending(providerID, value, desiredEnabled) {
        operationState = ProviderOperations.providerPendingChanged(
            operationState, providerMapKey(providerID), value, desiredEnabled)
    }

    function clearProviderFilters() {
        searchField.clear()
        searchField.forceActiveFocus(Qt.ShortcutFocusReason)
    }

    function copyObject(item) {
        return Guards.copyObject(item)
    }

    function hasOwnKey(item, key) {
        return Guards.hasOwnKey(item, key)
    }

    function isUnsafeObjectKey(key) {
        return Guards.isUnsafeObjectKey(key)
    }

    function providerMapKey(providerID) {
        var key = providerKey(providerID)
        return ProviderIdentity.providerMapKey(key)
    }

    function displayNameForProvider(providerID) {
        for (var i = 0; i < providers.length; i++) {
            if (providers[i].provider === providerID) {
                return providers[i].displayName
            }
        }
        return providerTitle(providerID)
    }

    function cfgValueOrEmpty(key) {
        try { return Plasmoid && Plasmoid.configuration ? String(Plasmoid.configuration[key] || "") : "" }
        catch (error) { return "" }
    }

    function providerAccessKind(providerID) {
        return ProviderIdentity.providerAccessKind(providerID)
    }

    function providerAccountUrl(providerID) {
        var url = providerLoginUrl(providerID)
        return url.length > 0 ? url : providerDashboardUrl(providerID)
    }

    // The same two buttons for every provider: Account, then Log in for a
    // subscription provider or API Key for a keyed one. Unsupported = greyed.
    function providerActionRows(item) {
        if (!item) {
            return []
        }
        var account = providerAccountUrl(item.provider)
        var rows = [{ title: i18n("Account"), icon: "user-identity", action: "login", url: account, enabled: account.length > 0 }]
        if (providerAccessKind(item.provider) === "subscription") {
            var login = loginStateFor(item.provider)
            rows.push({ title: i18n("Log in"), icon: "dialog-password", action: "cli-login", url: account,
                enabled: (loginSupported(item.provider) || account.length > 0) && (!login || login.state !== "starting") })
        } else {
            rows.push({ title: i18n("API Key"), icon: "dialog-password", action: "set-api-key",
                enabled: supportsApiKeySetup(item.provider) && !isPending(item.provider) && !loading
                    && !CommandLedger.hasKind(commands, "version") })
        }
        return rows
    }

    function descriptorActionIcon(action) {
        if (!action) {
            return "run-build"
        }
        if (action.id === "openDashboard") {
            return "view-statistics"
        }
        if (action.id === "openDocs") {
            return "help-contents"
        }
        if (action.id === "openLogin") {
            return "internet-services"
        }
        return "run-build"
    }

    // One persistent line: is CodexBar actually tracking this provider here?
    // Fed by the page-wide scan on load and by the per-provider refresh.
    function providerTrackingStatus(item) {
        if (!item) {
            return { state: "unknown", text: "" }
        }
        if (!item.enabled) {
            return { state: "off", text: i18n("Not tracked") }
        }
        var diagnostic = providerDiagnosticFor(item.provider)
        if (providerDiagnosticLoadingFor(item.provider)) {
            return { state: "checking", text: i18n("Checking…") }
        }
        if (!diagnostic) {
            return loading || detectionRescan.running || detectionRunning
                ? { state: "checking", text: i18n("Checking…") }
                : { state: "unknown", text: i18n("Not checked yet") }
        }
        if (diagnostic.fetchError.length > 0 || diagnostic.source === "failed" || diagnostic.source.length === 0) {
            return diagnostic.authConfigured
                ? { state: "error", text: diagnostic.fetchError.length > 0
                    ? i18n("Not tracked: %1", diagnostic.fetchError)
                    : i18n("Not tracked: last fetch failed.") }
                : { state: "error", text: i18n("Not tracked: no credentials or tool found.") }
        }
        return { state: "ok", text: i18n("Tracked via %1", sourceLabel(diagnostic.source)) }
    }

    function sourceLabel(source) {
        switch (String(source || "").toLowerCase()) {
        case "oauth": return i18n("OAuth login")
        case "api": return i18n("API key")
        case "web": return i18n("web session")
        case "cli": return i18n("the provider's CLI")
        default: return SafeText.cliMessage(source, 40)
        }
    }

    function descriptorFieldRows(item) {
        return item && item.descriptor && Array.isArray(item.descriptor.fields) ? item.descriptor.fields : []
    }

    function descriptorActionRows(item) {
        return item && item.descriptor && Array.isArray(item.descriptor.actions) ? item.descriptor.actions : []
    }

    function descriptorHasField(item, fieldID) {
        var fields = descriptorFieldRows(item)
        for (var i = 0; i < fields.length; i++) {
            if (fields[i].id === fieldID) {
                return true
            }
        }
        return false
    }

    function descriptorHasAction(item, actionID) {
        var actions = descriptorActionRows(item)
        for (var i = 0; i < actions.length; i++) {
            if (actions[i].id === actionID) {
                return true
            }
        }
        return false
    }

    function providerCliCommandText(item) {
        if (!item) {
            return ""
        }

        var providerID = item.provider
        var cliProviderID = providerCliArgument(providerID)
        var lines = [
            shellQuote(commandPath) + " usage --provider " + shellQuote(cliProviderID) + " --format json --json-only",
            shellQuote(commandPath) + " diagnose --provider " + shellQuote(cliProviderID) + " --format json --redact",
            shellQuote(commandPath) + " config " + (item.enabled ? "disable" : "enable") + " --provider " + shellQuote(cliProviderID) + " --format json --json-only"
        ]
        if (supportsApiKeySetup(providerID)) {
            lines.push("printf '%s' \"$API_KEY\" | " + shellQuote(commandPath) + " config set-api-key --provider " + shellQuote(cliProviderID) + " --stdin --format json --json-only")
        }
        return lines.join("\n")
    }

    function performProviderAction(row) {
        if (!row || !selectedProvider) {
            return
        }
        if (row.action === "descriptor-action") {
            runDescriptorAction(selectedProvider.provider, row.descriptorAction)
            return
        }
        if (row.action === "set-api-key") {
            setApiKey(selectedProvider.provider)
            return
        }
        if (row.action === "cli-login") {
            if (loginSupported(selectedProvider.provider)) {
                startLogin(selectedProvider.provider)
            } else if (row.url && row.url.length > 0) {
                Qt.openUrlExternally(row.url)
            }
            return
        }
        if (row.url && row.url.length > 0) {
            Qt.openUrlExternally(row.url)
        }
    }

    function writeDescriptorField(providerID, field, value) {
        if (!field || !field.writeCommand || field.writeCommand.length === 0 || isPending(providerID)
                || isFieldPending(providerID, field.id)) {
            return
        }
        // Every value written here ends up inside a shell command line, and
        // /proc/<pid>/cmdline stays world-readable while the child runs. Piping
        // the value through `sh -c script _ "$secret"` does not fix that: the
        // secret still lands in the shell argv. Secrets must go through
        // promptDescriptorSecret, which reads the value inside the script and
        // never puts it in a command line at all.
        var plan = ProviderDescriptor.planFieldWrite(field, value, commandPath)
        if (!plan.ok) {
            errorText = plan.reason !== "secretRequiresPrompt"
                ? i18n("%1 returned an unsupported descriptor command.", displayNameForProvider(providerID))
                : i18n("%1 secrets must be set through the secure prompt.", displayNameForProvider(providerID))
            return
        }
        errorText = ""
        statusText = ""
        markFieldPending(providerID, field.id, true)
        runCommand(plan.commandLine, {
            kind: "descriptorField",
            provider: providerID,
            fieldID: field.id,
            timeoutMs: configCommandTimeoutMs
        })
    }

    function promptDescriptorSecret(providerID, field) {
        if (!field || !field.writeCommand || field.writeCommand.length === 0 || isPending(providerID)
                || isFieldPending(providerID, field.id)) {
            return
        }
        var plan = ProviderDescriptor.planSecretPrompt(field, commandPath)
        if (!plan.ok) {
            errorText = i18n("%1 returned an unsupported descriptor command.", displayNameForProvider(providerID))
            return
        }
        errorText = ""
        statusText = ""
        markFieldPending(providerID, field.id, true)
        var prompt = i18n("%1 for %2", field.title, displayNameForProvider(providerID))
        var boundedDialogCommand = "timeout --kill-after="
            + shellQuote(configSecretPromptDialogKillAfterSeconds + "s") + " "
            + shellQuote(configSecretPromptDialogTimeoutSeconds + "s") + " "
            + "kdialog --password \"$1\""
        var boundedCommandLine = "timeout --kill-after="
            + shellQuote(configSecretCommandKillAfterSeconds + "s") + " "
            + shellQuote(configSecretCommandTimeoutSeconds + "s") + " "
            + plan.commandLine
        var script = [
            "if ! command -v kdialog >/dev/null 2>&1; then printf '%s\\n' '{\"error\":{\"message\":\"kdialog is required to prompt for secrets.\"}}'; exit 1; fi",
            "if ! command -v timeout >/dev/null 2>&1 || ! timeout --kill-after=1s 1s true >/dev/null 2>&1; then printf '%s\\n' '{\"error\":{\"message\":\"GNU timeout is required to save secrets safely.\"}}'; exit 1; fi",
            "value=$(" + boundedDialogCommand + " 2>/dev/null)",
            "status=$?",
            "if [ \"$status\" -ne 0 ] || [ -z \"$value\" ]; then printf '%s\\n' '{\"cancelled\":true}'; exit 0; fi",
            "printf '%s' \"$value\" | " + boundedCommandLine
        ].join("; ")
        var command = ["sh", "-c", shellQuote(script), "_", shellQuote(prompt)].join(" ")
        runCommand(command, {
            kind: "descriptorField",
            provider: providerID,
            fieldID: field.id,
            timeoutMs: configSecretPromptTimeoutMs
        })
    }

    function runDescriptorAction(providerID, action) {
        if (!action || !action.command || action.command.length === 0 || isPending(providerID)
                || isFieldPending(providerID, action.id)) {
            return
        }
        var plan = ProviderDescriptor.planAction(action, commandPath)
        if (!plan.ok) {
            errorText = i18n("%1 returned an unsupported descriptor command.", displayNameForProvider(providerID))
            return
        }
        errorText = ""
        statusText = ""
        markFieldPending(providerID, action.id, true)
        runCommand(plan.commandLine, {
            kind: "descriptorAction",
            provider: providerID,
            actionID: action.id,
            timeoutMs: configCommandTimeoutMs
        })
    }

    function optionIDAt(options, index) {
        if (!Array.isArray(options) || index < 0 || index >= options.length) {
            return ""
        }
        return options[index].id
    }

    function isFieldPending(providerID, fieldID) {
        return ProviderOperations.fieldPending(operationState, providerMapKey(providerID), fieldID)
    }

    function markFieldPending(providerID, fieldID, value) {
        operationState = ProviderOperations.fieldPendingChanged(
            operationState, providerMapKey(providerID), fieldID, value)
    }

    function hasPendingFields(providerID) {
        return ProviderOperations.hasFieldOperations(operationState, providerMapKey(providerID))
    }

    function supportsApiKeySetup(providerID) {
        switch (providerKey(providerID)) {
        case "munito":
            return munitoApiKeySetupSupported
        case "fireworks":
            return fireworksSingleKeySetupSupported
        case "commandcode":
        case "fal":
            return commandCodeFalApiKeySetupSupported
        case "aerostack":
        case "linkup":
        case "sailresearch":
        case "sofya":
        case "tavily":
        case "aixy":
        case "alibaba":
        case "amp":
        case "atlascloud":
        case "azureopenai":
        case "chutes":
        case "codebuff":
        case "clawrouter":
        case "copilot":
        case "crof":
        case "crossmodel":
        case "deepgram":
        case "devpass":
        case "doubao":
        case "elevenlabs":
        case "gitkraken":
        case "groq":
        case "ibmbob":
        case "kimi":
        case "kimik2":
        case "kilo":
        case "litellm":
        case "llmman":
        case "llmproxy":
        case "minimax":
        case "moonshot":
        case "ollama":
        case "openai":
        case "openrouter":
        case "poe":
        case "v0":
        case "venice":
        case "vercel":
        case "warp":
        case "xkiro":
        case "zai":
            return true
        default:
            return false
        }
    }

    function providerDocsUrl(providerID) {
        return ProviderIdentity.providerDocsUrl(providerID)
    }

    function providerDashboardUrl(providerID) {
        return ProviderIdentity.providerDashboardUrl(providerID)
    }

    function providerLoginUrl(providerID) {
        return ProviderIdentity.providerLoginUrl(providerID)
    }

    function providerConfigRevisionValue() {
        var current = Number(Plasmoid.configuration.providerConfigRevision || cfg_providerConfigRevision || 0)
        return isFinite(current) && current >= 0 ? Math.floor(current) : 0
    }

    function bumpProviderConfigRevision() {
        var current = providerConfigRevisionValue()
        var next = current >= 2147480000 ? 1 : current + 1
        cfg_providerConfigRevision = next
        Plasmoid.configuration.providerConfigRevision = next
    }

    function shellQuote(value) {
        return Guards.shellQuote(value)
    }

    // --- Provider visual identity (kept in sync with main.qml) ---

    function providerKey(value) {
        return ProviderIdentity.resolveProviderKey(value)
    }

    function providerCliArgument(value) {
        return ProviderIdentity.providerCliArgument(value)
    }

    function providerIconSource(value) {
        var fileName = ProviderIdentity.providerIconFileName(value)
        if (fileName.length === 0) {
            return "view-statistics"
        }
        return Qt.resolvedUrl("../icons/providers/" + fileName)
    }

    function providerColor(value) {
        var channels = ProviderIdentity.providerBrandColorChannels(value)
        if (channels.length !== 3) {
            return Kirigami.Theme.highlightColor
        }
        return Qt.rgba(channels[0], channels[1], channels[2], 1)
    }

    function withAlpha(color, alpha) {
        return Qt.rgba(color.r, color.g, color.b, alpha)
    }

    function providerReadableColor(value, background) {
        return ThemeContrast.readableAccentColor(
            providerColor(value),
            background || Kirigami.Theme.backgroundColor,
            Kirigami.Theme.textColor)
    }

    function providerTitle(value) {
        return providerNames.titleForKey(providerKey(value))
    }

    Timer {
        id: configCommandTimeoutTimer

        interval: 1000
        repeat: true
        running: page.hasTimedConfigCommands()
        triggeredOnStart: false
        onTriggered: page.expireConfigCommands(Date.now())
    }

    Components.ProviderNames {
        id: providerNames
    }

    Controllers.ManagedCliController {
        id: managedCli
        objectName: "managedCliController"
        commandPath: page.cfg_commandPath || "codexbar"
        onInstalled: function(path) {
            page.cfg_commandPath = path
        }
        // An update or install changes the version on the path; re-read it.
        onChanged: Qt.callLater(installedCliProbe.checkNow)
        Component.onCompleted: Qt.callLater(function() { managedCli.run("status") })
    }

    // Reads the version of whatever the widget currently runs.
    Controllers.CliUpdateController {
        id: installedCliProbe
        objectName: "installedCliProbe"
        commandPath: (page.cfg_commandPath || "codexbar").trim()
        localOnly: true
        Component.onCompleted: Qt.callLater(checkNow)
    }

    // What the last Update now click produced; cleared when a new one starts.
    property string cliUpdateOutcome: ""
    function updateCliNow() {
        if (managedCli.busy) return
        cliUpdateOutcome = ""
        cliUpdateRequested = true
        // Already on the private copy: update it. Otherwise install one and switch.
        managedCli.run(page.cliPathIsManaged ? "update" : "install")
    }
    property bool cliUpdateRequested: false
    readonly property string cliUpdateText: {
        if (managedCli.busy) return i18n("Checking for updates…")
        if (!cliUpdateRequested) return ""
        switch (managedCli.result.status) {
        case "installed": return i18n("Updated to %1", managedCli.result.version)
        case "ready": return i18n("Up to date")
        case "network": return i18n("Could not reach the release server")
        case "unsupported": return i18n("No official build for this system")
        case "busy": return i18n("Another widget is updating; try again shortly")
        default: return i18n("Update failed")
        }
    }

    readonly property bool cliPathIsManaged: managedCli.result.path.length > 0
        && (page.cfg_commandPath || "codexbar").trim() === managedCli.result.path
    readonly property string cliProbeText: {
        if (installedCliProbe.busy) return i18n("Checking…")
        if (!installedCliProbe.checked) return ""
        var result = installedCliProbe.result
        if (result.status === "local" && result.version.length > 0)
            return i18n("CodexBar %1", result.version)
        if (result.status === "missing") return i18n("CodexBar CLI not found")
        return i18n("CodexBar CLI unusable")
    }
    readonly property bool cliProbeOk: installedCliProbe.checked && !installedCliProbe.busy
        && installedCliProbe.result.status === "local" && installedCliProbe.result.version.length > 0

    // Checking "update daily" means: use the widget's private copy. Install it
    // first if it is missing; the install reply switches the path.
    function usePrivateCopy() {
        if (managedCli.result.version.length > 0) {
            page.cfg_commandPath = managedCli.result.path
        } else if (!managedCli.busy) {
            managedCli.run("install")
        }
    }


    // Aligns a hint with the label text of the check box it explains.
    function hintIndent(control) {
        return control.indicator ? control.indicator.width + control.spacing : 0
    }

    onCfg_refreshIntervalChanged: {
        var mins = Math.max(1, Math.round((Number(cfg_refreshInterval) || 300) / 60))
        if (refreshIntervalSpin.value !== mins) {
            refreshIntervalSpin.value = mins
        }
    }

    // ---- Provider CLI login, driven by scripts/provider-login.py ----
    readonly property var loginProviders: ["codex", "claude", "antigravity", "grok", "muse", "pi"]
    property var loginStates: ({})           // providerID -> last status object
    property string loginPollingFor: ""      // provider with an active flow
    readonly property string loginScriptPath: {
        var url = String(Qt.resolvedUrl("../../scripts/provider-login.py"))
        try { return url.indexOf("file:///") === 0 ? decodeURIComponent(url.slice(7)) : "" }
        catch (error) { return "" }
    }

    function loginSupported(providerID) {
        return loginProviders.indexOf(providerKey(providerID)) >= 0
    }
    function loginStateFor(providerID) {
        var key = providerMapKey(providerID)
        return key.length > 0 && hasOwnKey(loginStates, key) ? loginStates[key] : null
    }
    function setLoginState(providerID, state) {
        var key = providerMapKey(providerID)
        if (key.length === 0) return
        var next = copyObject(loginStates)
        if (state) next[key] = state; else delete next[key]
        loginStates = next
    }
    property int loginNonceSerial: 0
    function loginCommand(action, providerID, code) {
        loginNonceSerial += 1
        var nonce = "LOGIN_NONCE=" + loginNonceSerial + "_" + Date.now()
        var parts = [nonce, "timeout --kill-after=2s 40s python3", shellQuote(loginScriptPath), action,
                     "--provider", shellQuote(providerKey(providerID))]
        if (code !== undefined) parts.push("--code", shellQuote(code))
        return parts.join(" ")
    }
    function startLogin(providerID) {
        loginPollingFor = providerKey(providerID)
        setLoginState(providerID, { state: "starting", openedUrl: "" })
        loginSource.connectSource(loginCommand("start", providerID))
    }
    function pollLogin() {
        if (loginPollingFor.length > 0) loginSource.connectSource(loginCommand("status", loginPollingFor))
    }
    function submitLoginCode(providerID, code) {
        loginSource.connectSource(loginCommand("submit", providerID, code))
    }
    function cancelLogin(providerID) {
        loginSource.connectSource(loginCommand("cancel", providerID))
        loginPollingFor = ""
        setLoginState(providerID, null)
    }
    function dismissLogin(providerID) {
        loginSource.connectSource(loginCommand("cancel", providerID))
        setLoginState(providerID, null)
    }
    function acceptLoginStatus(providerID, value) {
        var state = value && typeof value === "object" ? copyObject(value) : { state: "failed" }
        var previous = loginStateFor(providerID)
        var openedUrl = previous && previous.openedUrl ? String(previous.openedUrl) : ""
        if (state.state === "done") {
            loginPollingFor = ""
            setLoginState(providerID, null)
            loginSource.connectSource(loginCommand("cancel", providerID))
            // credentials changed: re-check tracking and refresh usage
            invalidateProviderDiagnostic(providerID)
            loadProviderSettings(providerID)
            bumpProviderConfigRevision()
            return
        }
        if (["waiting", "needs_code"].indexOf(state.state) >= 0 && state.url && String(state.url) !== openedUrl) {
            openedUrl = String(state.url)
            Qt.openUrlExternally(openedUrl)
        }
        state.openedUrl = openedUrl
        setLoginState(providerID, state)
        if (["failed", "missing", "unsupported", "absent"].indexOf(state.state) >= 0) {
            loginPollingFor = ""
            loginFailureClear.providerID = providerID
            loginFailureClear.restart()
        }
    }

    Timer {
        id: detectionRescan
        interval: 3000
        onTriggered: page.scanDetectedProviders()
    }

    Plasma5Support.DataSource {
        id: loginSource
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
                page.acceptLoginStatus(providerID, value)
            }
        }
    }

    Timer {
        interval: 1500
        repeat: true
        running: page.loginPollingFor.length > 0
        onTriggered: page.pollLogin()
    }

    // A failure line clears itself; the tracking dot is the lasting signal.
    Timer {
        id: loginFailureClear
        property string providerID: ""
        interval: 12000
        onTriggered: page.dismissLogin(providerID)
    }

    Plasma5Support.DataSource {
        id: configSource

        engine: "executable"
        interval: 0

        onNewData: function(sourceName, data) {
            var rawStdoutText = data && data["stdout"] ? data["stdout"] : ""
            var stdoutText = SafeText.cliJsonText(rawStdoutText)
            var stderrText = data && data["stderr"] ? data["stderr"] : ""
            var exitCode = Guards.exitCode(data ? data["exit code"] : undefined)
            if (stdoutText === null) {
                stdoutText = ""
                stderrText = i18n("codexbar response exceeded the supported size.")
                exitCode = 1
            }
            disconnectSource(sourceName)
            page.handleData(sourceName, stdoutText, stderrText, exitCode)
        }
    }

    Kirigami.Action {
        id: clearProviderFiltersAction
        text: i18n("Clear filters")
        icon.name: "edit-clear"
        onTriggered: page.clearProviderFilters()
    }

    // Unlike FormLayout, a plain ColumnLayout does not reveal focused controls
    // in its enclosing ScrollablePage. Keep provider rows and their switches visible.
    function revealFocusedProviderControl() {
        var control = page.Window.activeFocusItem
        var ancestor = control
        while (ancestor && ancestor !== providerContent) {
            ancestor = ancestor.parent
        }
        if (!ancestor) {
            return
        }
        var position = page.flickable.contentItem.mapFromItem(control, 0, 0)
        page.ensureVisible(control, position.x - control.x, position.y - control.y)
    }

    Connections {
        target: page.Window
        enabled: page.visible

        function onActiveFocusItemChanged() {
            page.revealFocusedProviderControl()
        }
    }

    header: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.SearchField {
                id: searchField
                objectName: "providerSearchField"
                Layout.fillWidth: true
                placeholderText: i18n("Search providers")
                maximumLength: 256
                Accessible.name: placeholderText
                onTextChanged: page.filterText = text
            }

            Controls.BusyIndicator {
                running: page.detectionRunning
                visible: running
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Accessible.name: i18n("Scanning for installed providers")
            }

            Controls.CheckBox {
                objectName: "showAllProvidersCheck"
                text: i18n("Show all")
                checked: page.showAllProviders
                onToggled: page.showAllProviders = checked
                Accessible.description: i18n("Include providers with nothing detected on this system")
            }

            Controls.ToolButton {
                id: reloadProvidersButton

                text: i18n("Reload")
                display: Controls.AbstractButton.IconOnly
                padding: Kirigami.Units.smallSpacing
                contentItem: Kirigami.Icon {
                    // Breeze's 16 px refresh glyph has the boldest arrowheads;
                    // drawn as a mask so it follows the theme at any size.
                    source: Qt.resolvedUrl("../icons/refresh.svg")
                    isMask: true
                    color: Kirigami.Theme.textColor
                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                }
                enabled: !page.loading && !CommandLedger.hasKind(page.commands, "setSource")
                Accessible.name: i18n("Reload")

                Components.PlainToolTip {
                    parent: reloadProvidersButton
                    plainText: reloadProvidersButton.Accessible.name
                    visible: reloadProvidersButton.hovered || reloadProvidersButton.visualFocus
                    delay: Kirigami.Units.toolTipDelay
                }

                onClicked: {
                    page.detectedProviders = null
                    page.providerDiagnostics = ({})
                    page.reload()
                    page.scanDetectedProviders()
                }
            }
        }

        Components.PlainInlineMessage {
            id: providerErrorMessage

            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            type: Kirigami.MessageType.Error
            plainText: page.errorText
            visible: page.errorText.length > 0
            showCloseButton: true
            onVisibleChanged: {
                if (visible || page.errorText.length === 0) {
                    return
                }
                // Kirigami's close button hid the banner imperatively, severing
                // the visible binding; clear the text and reinstall the binding
                // so later errors still show up.
                page.errorText = ""
                visible = Qt.binding(function() { return page.errorText.length > 0 })
            }
        }

    }

    ColumnLayout {
        id: providerContent

        width: parent.width
        spacing: Kirigami.Units.smallSpacing

        // The selected provider and global CLI/refresh controls share one top surface.
        Rectangle {
            objectName: "selectedProviderSurface"

            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            implicitHeight: selectedProviderContent.implicitHeight + Kirigami.Units.largeSpacing * 2
            radius: Kirigami.Units.cornerRadius
            color: page.withAlpha(Kirigami.Theme.textColor, 0.035)
            visible: true

            ColumnLayout {
                id: selectedProviderContent

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    id: topCardColumns
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing
                    readonly property int topRowHeight: Kirigami.Units.iconSizes.medium + Kirigami.Units.smallSpacing * 2

                    // Left column: selected provider identity + actions.
                    ColumnLayout {
                        Layout.alignment: Qt.AlignTop
                        spacing: Kirigami.Units.smallSpacing
                        visible: page.selectedProvider !== null

                        RowLayout {
                            Layout.minimumHeight: topCardColumns.topRowHeight
                            Layout.bottomMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.largeSpacing

                            Rectangle {
                                readonly property color accent: page.selectedProvider
                                    ? page.providerReadableColor(
                                        page.selectedProvider.provider,
                                        Kirigami.Theme.backgroundColor)
                                    : Kirigami.Theme.textColor

                                Layout.alignment: Qt.AlignVCenter
                                Layout.preferredWidth: topCardColumns.topRowHeight
                                Layout.preferredHeight: topCardColumns.topRowHeight
                                radius: Kirigami.Units.cornerRadius
                                color: page.withAlpha(accent, 0.12)

                                Kirigami.Icon {
                                    anchors.centerIn: parent
                                    width: Kirigami.Units.iconSizes.medium
                                    height: Kirigami.Units.iconSizes.medium
                                    source: page.selectedProvider ? page.providerIconSource(page.selectedProvider.provider) : ""
                                    fallback: "view-statistics"
                                    isMask: true
                                    color: parent.accent
                                }
                            }

                            ColumnLayout {
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 0

                                Components.PlainHeading {
                                    text: page.selectedProvider ? page.selectedProvider.displayName : ""
                                    level: 4
                                    elide: Text.ElideRight
                                }

                                RowLayout {
                                    id: providerTrackingStatus
                                    objectName: "providerTrackingStatus"
                                    readonly property var status: page.providerTrackingStatus(page.selectedProvider)
                                    spacing: Kirigami.Units.smallSpacing

                                    Rectangle {
                                        readonly property string state: providerTrackingStatus.status.state
                                        Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                                        Layout.preferredHeight: Kirigami.Units.smallSpacing * 2
                                        radius: width / 2
                                        color: state === "ok" ? Kirigami.Theme.positiveTextColor
                                            : state === "error" ? Kirigami.Theme.negativeTextColor
                                            : "transparent"
                                        border.width: state === "ok" || state === "error" ? 0 : 1
                                        border.color: Kirigami.Theme.textColor
                                        opacity: state === "checking" ? 0.5 : 1
                                    }

                                    Components.PlainControlsLabel {
                                        text: providerTrackingStatus.status.text
                                        font: Kirigami.Theme.smallFont
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }

                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Repeater {
                                model: page.providerActionRows(page.selectedProvider)

                                delegate: Controls.Button {
                                    required property var modelData

                                    text: SafeText.plainButtonText(modelData.title, contentItem !== null)
                                    Accessible.name: modelData.title
                                    icon.name: modelData.icon
                                    enabled: modelData.enabled
                                    onClicked: page.performProviderAction(modelData)
                                }
                            }

                            Controls.ToolButton {
                                id: providerRefreshButton
                                objectName: "providerRefreshButton"
                                display: Controls.AbstractButton.IconOnly
                                padding: Kirigami.Units.smallSpacing
                                Accessible.name: i18n("Refresh tracking status")
                                contentItem: Kirigami.Icon {
                                    source: Qt.resolvedUrl("../icons/refresh.svg")
                                    isMask: true
                                    color: Kirigami.Theme.textColor
                                    implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                    implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                }
                                enabled: page.selectedProvider
                                    && !page.isPending(page.selectedProvider.provider)
                                    && !page.providerDiagnosticLoadingFor(page.selectedProvider.provider)
                                onClicked: if (page.selectedProvider) page.loadProviderSettings(page.selectedProvider.provider)

                                Components.PlainToolTip {
                                    parent: providerRefreshButton
                                    plainText: providerRefreshButton.Accessible.name
                                    visible: providerRefreshButton.hovered || providerRefreshButton.visualFocus
                                    delay: Kirigami.Units.toolTipDelay
                                }
                            }

                            Controls.BusyIndicator {
                                running: page.selectedProvider !== null
                                    && page.providerDiagnosticLoadingFor(page.selectedProvider.provider)
                                visible: running
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // Middle column: CodexBar CLI version & update controls.
                    ColumnLayout {
                        Layout.alignment: Qt.AlignTop | Qt.AlignHCenter
                        spacing: Kirigami.Units.smallSpacing

                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.minimumHeight: topCardColumns.topRowHeight
                            Layout.bottomMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            Components.PlainHeading {
                                objectName: "cliVersionLabel"
                                text: page.cliProbeText
                                level: 4
                                color: page.cliProbeOk || installedCliProbe.busy ? Kirigami.Theme.textColor : Kirigami.Theme.negativeTextColor
                            }

                            Components.PlainControlsLabel {
                                objectName: "cliUpdateOutcomeLabel"
                                text: page.cliUpdateText
                                visible: text.length > 0
                                font: Kirigami.Theme.smallFont
                                opacity: page.secondaryTextOpacity
                            }
                        }

                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Button {
                                id: cliUpdateNowButton
                                objectName: "cliUpdateNowButton"
                                Accessible.name: i18n("Update now")
                                enabled: !managedCli.busy
                                leftPadding: Kirigami.Units.largeSpacing
                                rightPadding: Kirigami.Units.largeSpacing
                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing
                                    Kirigami.Icon {
                                        source: Qt.resolvedUrl("../icons/refresh.svg")
                                        isMask: true
                                        color: Kirigami.Theme.textColor
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: Kirigami.Units.iconSizes.small
                                    }
                                    Components.PlainControlsLabel { text: i18n("Update now") }
                                }
                                onClicked: page.updateCliNow()
                            }

                            Controls.CheckBox {
                                objectName: "cliAutomaticUpdatesCheck"
                                text: i18n("Update daily")
                                checked: page.cfg_cliAutomaticUpdates
                                enabled: !managedCli.busy
                                onToggled: {
                                    page.cfg_cliAutomaticUpdates = checked
                                    if (checked) page.usePrivateCopy()
                                }
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // Right column: Refresh cadence, on pop-up open, hide account names.
                    ColumnLayout {
                        Layout.alignment: Qt.AlignTop | Qt.AlignRight
                        spacing: Kirigami.Units.smallSpacing

                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            Layout.minimumHeight: topCardColumns.topRowHeight
                            Layout.bottomMargin: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            Components.PlainControlsLabel { text: i18n("Refresh:") }

                            Controls.SpinBox {
                                id: refreshIntervalSpin
                                objectName: "refreshIntervalSpin"
                                from: 1
                                to: 1440
                                stepSize: {
                                    if (holdTicks >= 20) return 60
                                    if (holdTicks >= 12) return 30
                                    if (holdTicks >= 7) return 10
                                    if (holdTicks >= 3) return 5
                                    if (holdTicks >= 1) return 2
                                    return 1
                                }
                                editable: true
                                wheelEnabled: true
                                implicitWidth: Math.round(Kirigami.Units.gridUnit * 3.2)
                                Layout.preferredWidth: Math.round(Kirigami.Units.gridUnit * 3.2)
                                Layout.maximumWidth: Math.round(Kirigami.Units.gridUnit * 3.2)
                                value: Math.max(1, Math.round((Number(page.cfg_refreshInterval) || 300) / 60))

                                property int holdTicks: 0
                                property bool arrowKeyHeld: false
                                readonly property bool spinning: (up && up.pressed) || (down && down.pressed) || arrowKeyHeld

                                onSpinningChanged: {
                                    if (!spinning) holdTicks = 0
                                }

                                Timer {
                                    interval: 150
                                    repeat: true
                                    running: refreshIntervalSpin.spinning
                                    onTriggered: refreshIntervalSpin.holdTicks += 1
                                }

                                Timer {
                                    id: wheelResetTimer
                                    interval: 220
                                    onTriggered: if (!refreshIntervalSpin.spinning) refreshIntervalSpin.holdTicks = 0
                                }

                                WheelHandler {
                                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                    onWheel: function(event) {
                                        refreshIntervalSpin.holdTicks = Math.min(25, refreshIntervalSpin.holdTicks + 1)
                                        wheelResetTimer.restart()
                                        event.accepted = false
                                    }
                                }

                                Keys.onUpPressed: function(event) {
                                    arrowKeyHeld = event.isAutoRepeat
                                    if (!event.isAutoRepeat) holdTicks = 0
                                    event.accepted = false
                                }
                                Keys.onDownPressed: function(event) {
                                    arrowKeyHeld = event.isAutoRepeat
                                    if (!event.isAutoRepeat) holdTicks = 0
                                    event.accepted = false
                                }
                                Keys.onReleased: function(event) {
                                    if (!event.isAutoRepeat && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
                                        arrowKeyHeld = false
                                        holdTicks = 0
                                    }
                                }

                                valueFromText: function(text, locale) {
                                    var match = String(text || "").match(/\d+/)
                                    return match ? Math.min(1440, Math.max(1, parseInt(match[0], 10))) : value
                                }
                                onValueModified: {
                                    page.cfg_refreshInterval = value * 60
                                }
                                Keys.onReturnPressed: function(event) {
                                    event.accepted = true
                                    if (contentItem && contentItem.text !== undefined) {
                                        value = valueFromText(contentItem.text, locale)
                                        page.cfg_refreshInterval = value * 60
                                    }
                                    focus = false
                                }
                                Keys.onEnterPressed: function(event) {
                                    event.accepted = true
                                    if (contentItem && contentItem.text !== undefined) {
                                        value = valueFromText(contentItem.text, locale)
                                        page.cfg_refreshInterval = value * 60
                                    }
                                    focus = false
                                }
                            }

                            Components.PlainControlsLabel { text: i18n("min") }
                        }

                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            spacing: Kirigami.Units.largeSpacing

                            Controls.CheckBox {
                                id: refreshOnOpenCheck
                                objectName: "refreshOnOpenCheck"
                                text: i18n("On pop-up open")
                            }
                        }
                    }
                }

                ColumnLayout {
                    id: loginPanel
                    objectName: "providerLoginPanel"
                    readonly property string providerID: page.selectedProvider ? page.selectedProvider.provider : ""
                    readonly property var login: page.loginStateFor(providerID)
                    readonly property string state: login ? String(login.state || "") : ""
                    visible: state.length > 0
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Components.PlainControlsLabel {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: {
                            switch (loginPanel.state) {
                            case "starting": return i18n("Starting…")
                            case "waiting": return loginPanel.login.deviceCode
                                ? i18n("Finish in your browser. Enter code %1 when asked.", loginPanel.login.deviceCode)
                                : i18n("Finish signing in in your browser.")
                            case "needs_code": return i18n("Paste the code from the browser:")
                            case "failed": return i18n("Sign-in did not complete.")
                            case "missing": return i18n("%1 is not installed.", loginPanel.login.tool || "")
                            default: return ""
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        visible: loginPanel.state === "needs_code"

                        Controls.TextField {
                            id: loginCodeField
                            Layout.fillWidth: true
                            placeholderText: i18n("Authorization code")
                            onAccepted: if (text.trim().length > 0) { page.submitLoginCode(loginPanel.providerID, text.trim()); text = "" }
                        }
                        Controls.Button {
                            text: i18n("Submit")
                            enabled: loginCodeField.text.trim().length > 0
                            onClicked: { page.submitLoginCode(loginPanel.providerID, loginCodeField.text.trim()); loginCodeField.text = "" }
                        }
                    }

                    Components.PlainControlsLabel {
                        Layout.fillWidth: true
                        visible: loginPanel.state === "failed" && loginPanel.login.tail ? true : false
                        text: loginPanel.login && loginPanel.login.tail ? SafeText.cliMessage(loginPanel.login.tail, 400) : ""
                        font: Kirigami.Theme.smallFont
                        opacity: page.secondaryTextOpacity
                        wrapMode: Text.Wrap
                    }

                    RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Controls.Button {
                            visible: ["starting", "waiting", "needs_code"].indexOf(loginPanel.state) >= 0
                            text: i18n("Cancel")
                            icon.name: "dialog-cancel"
                            onClicked: page.cancelLogin(loginPanel.providerID)
                        }
                    }
                }

                ColumnLayout {
                    id: providerSettingsDetails

                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Components.PlainInlineMessage {
                        Layout.fillWidth: true
                        type: Kirigami.MessageType.Error
                        plainText: page.selectedProvider
                            ? page.providerDiagnosticErrorFor(page.selectedProvider.provider)
                            : ""
                        visible: plainText.length > 0
                        showCloseButton: true
                        onVisibleChanged: {
                            // Kirigami's close button hides the banner imperatively,
                            // severing the visible binding. Clear the stored error so
                            // the dismissal sticks, then reinstall the binding so the
                            // next diagnostic error still shows up. Collapsing the
                            // parent details is not a dismissal of the error.
                            if (!visible && plainText.length > 0 && page.selectedProvider) {
                                page.setProviderDiagnosticError(page.selectedProvider.provider, "")
                                visible = Qt.binding(function() { return plainText.length > 0 })
                            }
                        }
                    }

                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 8
            visible: page.loading && page.providers.length === 0

            Controls.BusyIndicator {
                anchors.centerIn: parent
                running: parent.visible
            }
        }

        Kirigami.Separator {
            id: providerListSeparator

            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: page.providers.length > 0
        }

        RowLayout {
            id: providerListHeading

            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            visible: page.providers.length > 0

            Components.PlainControlsLabel {
                text: i18n("Providers")
                font.weight: Font.DemiBold
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            Components.PlainControlsLabel {
                objectName: "providerScanStatus"
                visible: page.detectionRunning
                text: i18n("Scanning this system for installed providers…")
                font: Kirigami.Theme.smallFont
                opacity: page.secondaryTextOpacity
                elide: Text.ElideRight
            }
        }

        Components.PlainPlaceholderMessage {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 2
            visible: !page.loading && page.providers.length === 0 && page.errorText.length === 0
            icon.name: "view-list-details"
            plainText: i18n("No providers reported")
            plainExplanation: i18n("codexbar did not return any providers.")
        }

        Components.PlainPlaceholderMessage {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 2
            visible: page.providers.length > 0 && page.visibleProviders.length === 0
            icon.name: "search"
            plainText: i18n("No matching providers")
            plainExplanation: i18n("Try another search or choose a different filter.")
            helpfulAction: clearProviderFiltersAction
        }

        Components.PlainControlsLabel {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            visible: page.filterScope === "all" && page.visibleEnabledProviders.length > 0
            text: i18n("Enabled")
            font: Kirigami.Theme.smallFont
            opacity: page.secondaryTextOpacity
        }

        Repeater {
            model: page.visibleEnabledProviders

            delegate: Components.ProviderConfigRow {
                configPage: page
            }
        }

        Components.PlainControlsLabel {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: page.visibleEnabledProviders.length > 0 ? Kirigami.Units.largeSpacing : 0
            visible: page.filterScope === "all" && page.visibleDisabledProviders.length > 0
            text: i18n("Disabled")
            font: Kirigami.Theme.smallFont
            opacity: page.secondaryTextOpacity
        }

        Repeater {
            model: page.visibleDisabledProviders

            delegate: Components.ProviderConfigRow {
                configPage: page
            }
        }
    }
}
