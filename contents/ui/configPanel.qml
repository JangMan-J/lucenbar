import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import "components" as Components
import "controllers" as Controllers
import "PanelDisplay.js" as PanelDisplay
import "ProviderOrder.js" as ProviderOrder
import "QuotaThresholds.js" as QuotaThresholds

KCM.SimpleKCM {
    id: page

    readonly property Controls.ScrollView scrollView: contentItem as Controls.ScrollView

    // Reserve the themed scrollbar width even when initial overflow disappears.
    Binding {
        target: page.scrollView
        property: page.mirrored ? "leftPadding" : "rightPadding"
        value: page.scrollView.Controls.ScrollBar.vertical.implicitWidth
    }

    property string cfg_menuBarDisplayMode: "percent"
    property string cfg_menuBarDisplayModeDefault: "percent"
    property string cfg_panelMeterStyle: "bars"
    property string cfg_panelMeterStyleDefault: "bars"
    property real cfg_panelMeterScale: 0.75
    property real cfg_panelMeterScaleDefault: 0.75
    property alias cfg_showPercentInPanel: showPercentCheck.checked
    property bool cfg_showPercentInPanelDefault: false
    property alias cfg_showProviderIconsInPanel: showProviderIconsCheck.checked
    property bool cfg_showProviderIconsInPanelDefault: true
    property alias cfg_showMultiProviderInPanel: showMultiProviderCheck.checked
    property bool cfg_showMultiProviderInPanelDefault: true
    property string cfg_panelQuotaLane: "auto"
    property string cfg_panelQuotaLaneDefault: "auto"
    property string cfg_panelProviderIDs: ""
    property string cfg_panelProviderIDsDefault: ""
    property string cfg_providerOrder: ""
    property alias cfg_usageBarsShowUsed: usageBarsShowUsedCheck.checked
    property bool cfg_usageBarsShowUsedDefault: false
    property alias cfg_showPopupPace: showPopupPaceCheck.checked
    property bool cfg_showPopupPaceDefault: true
    property alias cfg_showPopupCredits: showPopupCreditsCheck.checked
    property bool cfg_showPopupCreditsDefault: true
    property alias cfg_showPopupProviderDetails: showPopupProviderDetailsCheck.checked
    property bool cfg_showPopupProviderDetailsDefault: true
    property alias cfg_showPopupTabLabels: showPopupTabLabelsCheck.checked
    property bool cfg_showPopupTabLabelsDefault: true
    property alias cfg_resetTimesShowAbsolute: resetTimesShowAbsoluteCheck.checked
    property bool cfg_resetTimesShowAbsoluteDefault: false
    property alias cfg_privacyMode: privacyModeCheck.checked
    property bool cfg_privacyModeDefault: false
    property string cfg_providerOrderDefault: ""
    property alias cfg_autoSelectProvider: autoSelectProviderCheck.checked
    property bool cfg_autoSelectProviderDefault: false
    property alias cfg_showCreditsInPanel: showCreditsCheck.checked
    property bool cfg_showCreditsInPanelDefault: false
    // Other pages' settings, read for the preview. The page can be instantiated
    // before its Plasmoid context exists, so every read goes through cfgValue().
    readonly property var presentationConfig: {
        try { return (Plasmoid && Plasmoid.configuration) || ({}) } catch (error) { return ({}) }
    }
    function cfgValue(key) {
        var config = presentationConfig
        return config ? config[key] : undefined
    }
    readonly property bool usageBarsShowUsed: cfg_usageBarsShowUsed === true

    // The panel provider selection needs the enabled roster, but this page
    // stays process-free: the shared controller loads it only while the
    // selection is expanded, reading the command path at runtime instead of
    // claiming the Diagnostics-owned command-path key.
    readonly property var orderedPanelProviderRoster: ProviderOrder.orderedItems(
        panelProviderRosterController.enabledProviderRoster, cfg_providerOrder)
    readonly property alias panelProviderRosterLoading: panelProviderRosterController.providerRosterLoading
    readonly property alias panelProviderRosterError: panelProviderRosterController.providerRosterError

    Controllers.ProviderRosterController {
        id: panelProviderRosterController
        objectName: "panelProviderRosterController"

        commandPath: (cfgValue("commandPath") || "codexbar").trim()
        active: true
    }

    // Panel text is one choice: the name and usage segments are not
    // independent in practice because the fitter surrenders one for the other.
    readonly property bool panelTextVisible: cfg_showPercentInPanel || cfg_showCreditsInPanel
    // Two windows (session and weekly) or one. Legacy single-lane values count as one.
    readonly property bool doubleQuotaWindows: PanelDisplay.safeLane(cfg_panelQuotaLane) === "auto"

    function meterStyleIndex(value) {
        return value === "rings" ? 1 : (value === "logos" ? 2 : 0)
    }

    function meterDepthIndex(value) {
        return PanelDisplay.safeLane(value) === "auto" ? 1 : 0
    }

    function displayModeIndex(value) {
        for (var i = 0; i < displayModeCombo.model.length; i++) {
            if (displayModeCombo.model[i].value === value) {
                return i
            }
        }
        return 0
    }

    onCfg_panelMeterStyleChanged: {
        var nextIndex = meterStyleIndex(cfg_panelMeterStyle)
        if (meterStyleCombo.currentIndex !== nextIndex) {
            meterStyleCombo.currentIndex = nextIndex
        }
    }

    onCfg_panelQuotaLaneChanged: {
        var nextIndex = meterDepthIndex(cfg_panelQuotaLane)
        if (meterDepthCombo.currentIndex !== nextIndex) {
            meterDepthCombo.currentIndex = nextIndex
        }
    }

    onCfg_menuBarDisplayModeChanged: {
        var nextIndex = displayModeIndex(cfg_menuBarDisplayMode)
        if (displayModeCombo.currentIndex !== nextIndex) {
            displayModeCombo.currentIndex = nextIndex
        }
    }

    header: Item {
        implicitHeight: panelPreview.implicitHeight + Kirigami.Units.smallSpacing * 2

        Components.PanelSettingsPreview {
            id: panelPreview
            objectName: "panelSettingsPreview"
            anchors.top: parent.top
            anchors.topMargin: Kirigami.Units.smallSpacing
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(0, Math.min(parent.width - Kirigami.Units.largeSpacing * 2,
                Kirigami.Units.gridUnit * 24))
            configPage: page
            usageBarsShowUsed: page.usageBarsShowUsed
            resetTimesShowAbsolute: page.cfg_resetTimesShowAbsolute === true
            showQuotaWarningMarkers: cfgValue("showQuotaWarningMarkers") !== false
            quotaWarningPercent: QuotaThresholds.warningPercent(cfgValue("quotaWarningPercent"))
            quotaCriticalPercent: QuotaThresholds.criticalPercent(quotaWarningPercent, cfgValue("quotaCriticalPercent"))
            providerOrder: page.cfg_providerOrder
        }
    }

    Kirigami.FormLayout {
        Kirigami.Separator {
            Kirigami.FormData.label: i18n("Panel Appearance")
            Kirigami.FormData.isSection: true
        }

        Controls.ComboBox {
            id: meterStyleCombo
            objectName: "panelMeterStyleCombo"
            Kirigami.FormData.label: i18n("Meter style:")
            textRole: "text"
            valueRole: "value"
            model: [
                {
                    text: i18n("Bars"),
                    value: "bars",
                    description: i18n("Horizontal capsule bars, stacked per quota window.")
                },
                {
                    text: i18n("Rings"),
                    value: "rings",
                    description: i18n("Concentric rings with session quota outside and weekly quota inside.")
                },
                {
                    text: i18n("Logos"),
                    value: "logos",
                    description: i18n("Provider logos act as the meters, dimming in brightness.")
                }
            ]
            Layout.preferredWidth: Kirigami.Units.gridUnit * 19
            Component.onCompleted: currentIndex = page.meterStyleIndex(page.cfg_panelMeterStyle)
            onActivated: page.cfg_panelMeterStyle = currentValue
        }

        Components.PlainControlsLabel {
            Layout.fillWidth: true
            Layout.preferredWidth: Kirigami.Units.gridUnit * 24
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
            text: meterStyleCombo.currentIndex >= 0
                ? meterStyleCombo.model[meterStyleCombo.currentIndex].description : ""
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }

        Controls.ComboBox {
            id: meterDepthCombo
            objectName: "panelMeterDepthCombo"
            Kirigami.FormData.label: i18n("Meter depth:")
            textRole: "text"
            valueRole: "value"
            model: [
                {
                    text: i18n("Single window"),
                    value: "primary",
                    description: i18n("Shows the session quota window only.")
                },
                {
                    text: i18n("Dual windows"),
                    value: "auto",
                    description: i18n("Shows both session and weekly quota windows when available.")
                }
            ]
            Layout.preferredWidth: Kirigami.Units.gridUnit * 19
            Component.onCompleted: currentIndex = page.meterDepthIndex(page.cfg_panelQuotaLane)
            onActivated: page.cfg_panelQuotaLane = currentValue
        }

        Components.PlainControlsLabel {
            Layout.fillWidth: true
            Layout.preferredWidth: Kirigami.Units.gridUnit * 24
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
            text: meterDepthCombo.currentIndex >= 0
                ? meterDepthCombo.model[meterDepthCombo.currentIndex].description : ""
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }

        Kirigami.Separator {
            Kirigami.FormData.label: i18n("Panel Contents")
            Kirigami.FormData.isSection: true
        }

        Controls.CheckBox {
            id: showMultiProviderCheck
            Layout.fillWidth: true
            text: i18n("Show meters")
        }

        Controls.CheckBox {
            id: showProviderIconsCheck
            objectName: "panelProviderIconsCheck"
            Layout.fillWidth: true
            enabled: page.cfg_panelMeterStyle !== "logos"
            text: i18n("Show provider logos")
        }

        Controls.CheckBox {
            id: showPercentCheck
            objectName: "panelUsageTextCheck"
            Layout.fillWidth: true
            text: i18n("Show usage text (horizontal panels)")
        }

        Controls.ComboBox {
            id: displayModeCombo
            objectName: "panelTextMode"
            Kirigami.FormData.label: i18n("Text shows:")
            textRole: "text"
            valueRole: "value"
            model: [
                {
                    text: page.usageBarsShowUsed
                        ? i18n("Percent used")
                        : i18n("Percent left"),
                    value: PanelDisplay.percentMode,
                    description: ""
                },
                {
                    text: i18n("Pace"), value: PanelDisplay.paceMode,
                    description: i18n("Shows the expected used or left percentage at this point in the window.")
                },
                {
                    text: i18n("Usage and pace"), value: PanelDisplay.bothMode,
                    description: i18n("Shows current usage alongside the expected used or left percentage.")
                },
                {
                    text: i18n("Reset time"), value: PanelDisplay.resetTimeMode,
                    description: i18n("Appears when the provider supplies a reset time.")
                },
                {
                    text: i18n("Run-out forecast"), value: PanelDisplay.runOutMode,
                    description: i18n("Appears only when the quota is forecast to run out before reset.")
                }
            ]
            enabled: page.cfg_showPercentInPanel
            Layout.preferredWidth: Kirigami.Units.gridUnit * 19
            onModelChanged: currentIndex = page.displayModeIndex(page.cfg_menuBarDisplayMode)
            Component.onCompleted: currentIndex = page.displayModeIndex(page.cfg_menuBarDisplayMode)
            onActivated: page.cfg_menuBarDisplayMode = currentValue
        }

        Components.PlainControlsLabel {
            id: displayModeDescription

            Layout.fillWidth: true
            Layout.preferredWidth: Kirigami.Units.gridUnit * 24
            Layout.maximumWidth: Kirigami.Units.gridUnit * 24
            text: displayModeCombo.currentIndex >= 0
                ? displayModeCombo.model[displayModeCombo.currentIndex].description : ""
            visible: page.cfg_showPercentInPanel && text.length > 0
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }

        Controls.CheckBox {
            id: showCreditsCheck
            Layout.fillWidth: true
            text: i18n("Add credits to the text")
        }

        Controls.CheckBox {
            id: autoSelectProviderCheck
            Layout.fillWidth: true
            text: i18n("Auto-select the busiest provider")
        }

        Kirigami.Separator {
            Kirigami.FormData.label: i18n("Popup Appearance")
            Kirigami.FormData.isSection: true
        }

        Controls.CheckBox {
            id: usageBarsShowUsedCheck
            Layout.fillWidth: true
            text: i18n("Show percent used instead of percent left")
        }

        Controls.CheckBox {
            id: resetTimesShowAbsoluteCheck
            Layout.fillWidth: true
            text: i18n("Show reset times as clock times")
        }

        Controls.CheckBox {
            id: privacyModeCheck
            objectName: "privacyModeCheck"
            Layout.fillWidth: true
            text: i18n("Hide account names")
        }

        Kirigami.Separator {
            Kirigami.FormData.label: i18n("Popup Contents")
            Kirigami.FormData.isSection: true
        }

        Controls.CheckBox {
            id: showPopupPaceCheck
            objectName: "showPopupPaceCheck"
            Layout.fillWidth: true
            text: i18n("Show pace forecasts")
        }

        Controls.CheckBox {
            id: showPopupCreditsCheck
            objectName: "showPopupCreditsCheck"
            Layout.fillWidth: true
            text: i18n("Show credits")
        }

        Controls.CheckBox {
            id: showPopupProviderDetailsCheck
            objectName: "showPopupProviderDetailsCheck"
            Layout.fillWidth: true
            text: i18n("Show details and charts")
        }

        Controls.CheckBox {
            id: showPopupTabLabelsCheck
            Layout.fillWidth: true
            text: i18n("Label the tabs")
        }

    }
}
