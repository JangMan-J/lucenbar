import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "../PanelDisplay.js" as PanelDisplay
import "../PanelPreview.js" as PanelPreview
import "../PanelTextFit.js" as PanelTextFit
import "../ProviderIdentity.js" as ProviderIdentity
import "../ProviderOrder.js" as ProviderOrder
import "../QuotaThresholds.js" as QuotaThresholds
import "../ThemeContrast.js" as ThemeContrast

ColumnLayout {
    id: preview

    required property var configPage
    property bool usageBarsShowUsed: false
    property bool resetTimesShowAbsolute: false
    property bool showQuotaWarningMarkers: true
    property int quotaWarningPercent: QuotaThresholds.defaultWarningPercent
    property int quotaCriticalPercent: QuotaThresholds.defaultCriticalPercent
    property string providerOrder: ""
    property string scenario: "normal"
    readonly property real clockMs: Date.now()
    readonly property var previewModel: PanelPreview.model({
        quotaLane: configPage.cfg_panelQuotaLane,
        displayMode: configPage.cfg_menuBarDisplayMode,
        showMeters: configPage.cfg_showMultiProviderInPanel,
        autoSelectProvider: configPage.cfg_autoSelectProvider,
        providerOrder: providerOrder,
        providerRoster: configPage.orderedPanelProviderRoster,
        panelProviderFilter: configPage.cfg_panelProviderIDs || ""
    }, scenario, clockMs)

    objectName: "panelSettingsPreview"
    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing

    function metricText(row) {
        if (!row) {
            return "";
        }
        var suffix = usageBarsShowUsed ? i18n("used") : i18n("left");
        var percent = i18n("%1% %2", Math.round(previewApplet.displayPercent(row)), suffix);
        var pace = Math.round(usageBarsShowUsed ? row.pacePercent : Math.max(0, 100 - row.pacePercent));
        var paceText = row.paceOnTop ? i18n("%1% %2 at pace", pace, suffix) : i18n("%1% %2, behind pace", pace, suffix);
        switch (previewModel.mode) {
        case "pace":
            return paceText;
        case "both":
            return i18n("%1 - %2", percent, paceText);
        case "runOut":
            if (!PanelDisplay.rowHasRunOut(row)) {
                return "";
            }
            var minutes = Math.max(1, Math.round(row.paceEtaSeconds / 60));
            if (minutes < 60) {
                return i18np("%1 minute", "%1 minutes", minutes);
            }
            var hours = Math.max(1, Math.round(minutes / 60));
            return hours < 48 ? i18np("%1 hour", "%1 hours", hours)
                : i18np("%1 day", "%1 days", Math.max(1, Math.round(hours / 24)));
        case "resetTime":
            if (resetTimesShowAbsolute) {
                return i18n("Resets %1", timeLabels.weekdayTime(Date.parse(row.resetsAt)));
            }
            var resetMinutes = Math.max(1, Math.round(row.resetMinutes));
            if (resetMinutes < 60) {
                return i18n("Resets %1", i18np("%1 min", "%1 min", resetMinutes));
            }
            var resetHours = Math.floor(resetMinutes / 60);
            var restMinutes = resetMinutes % 60;
            if (resetHours < 24) {
                return i18n("Resets %1", restMinutes > 0 ? i18n("%1h %2m", resetHours, restMinutes)
                    : i18np("%1h", "%1h", resetHours));
            }
            var resetDays = Math.floor(resetHours / 24);
            var restHours = resetHours % 24;
            return i18n("Resets %1", restHours > 0 ? i18n("%1d %2h", resetDays, restHours)
                : i18np("%1d", "%1d", resetDays));
        default:
            return percent;
        }
    }

    function accessibleSummary() {
        var parts = [];
        var text = previewApplet.compactText();
        if (text.length > 0) {
            parts.push(text);
        }
        for (var i = 0; i < previewModel.meterProviders.length; i++) {
            var provider = previewModel.meterProviders[i];
            parts.push(provider.title + ": " + previewApplet.panelMeterDescription(provider));
        }
        if (previewModel.incidentProvider) {
            parts.push(i18n("Service incident"));
        }
        return parts.length > 0 ? parts.join(". ") : i18n("Provider icon");
    }

    function providerColor(value) {
        var channels = ProviderIdentity.providerBrandColorChannels(value);
        if (channels.length !== 3) {
            return Kirigami.Theme.highlightColor;
        }
        return Qt.rgba(channels[0], channels[1], channels[2], 1);
    }

    function withAlpha(color, alpha) {
        return Qt.rgba(color.r, color.g, color.b, alpha);
    }

    TimeLabels {
        id: timeLabels
    }

    QtObject {
        id: previewApplet

        readonly property bool verticalFormFactor: false
        readonly property bool minimalPanel: preview.previewModel.minimalStyle
        readonly property bool ringMeters: configPage.cfg_panelMeterStyle === "rings"
        readonly property bool logoMeters: configPage.cfg_panelMeterStyle === "logos"
        readonly property bool panelProviderIcons: configPage.cfg_showProviderIconsInPanel !== false
        readonly property real panelMeterScale: Math.min(1, Math.max(0.5, Number(configPage.cfg_panelMeterScale) || 0.75))
        readonly property bool loading: false

        function providerPresentation(provider) {
            return provider;
        }
        function panelElementOrder() {
            return preview.previewModel.elementOrder;
        }
        function compactProviders() {
            return preview.previewModel.meterProviders;
        }
        function reorderPanelProviders(providerID, beforeProviderID) {
            var source = ProviderOrder.normalizedProviderID(providerID);
            var before = ProviderOrder.normalizedProviderID(beforeProviderID || "");
            if (source.length === 0 || source === before) return;
            var ids = configPage.orderedPanelProviderRoster.map(function(item) {
                return ProviderOrder.normalizedProviderID(item.provider);
            }).filter(function(id) { return id !== source; });
            var at = before.length > 0 ? ids.indexOf(before) : -1;
            if (at < 0) ids.push(source); else ids.splice(at, 0, source);
            configPage.cfg_providerOrder = ids.join(",");
        }
        function primaryIncidentProvider() {
            var provider = preview.previewModel.incidentProvider;
            return provider ? {
                provider: provider.provider,
                title: provider.title,
                hasIncident: true,
                statusSeverity: provider.statusSeverity,
                status: i18n("Service incident")
            } : null;
        }
        function selectedCompactProvider() {
            return preview.previewModel.selectedProvider;
        }
        function panelDisplayRow(provider, mode) {
            return PanelDisplay.rowForMode(provider ? provider.rows : [], mode, preview.previewModel.lane);
        }
        function panelMeterRows(provider) {
            // Repeater wraps nested arrays as Qt sequences. Use the original fixture rows.
            var source = preview.previewModel.providers.find(function(item) {
                return provider && item.provider === provider.provider;
            });
            return PanelDisplay.meterRows(source ? source.rows : [], preview.previewModel.lane);
        }
        function panelMeterDescription(provider) {
            return panelMeterRows(provider).map(function(row) {
                var label = row.lane === "primary" ? i18n("Primary")
                    : (row.lane === "secondary" ? i18n("Secondary") : i18n("Tertiary"));
                return i18n("%1: %2% %3", label, Math.round(displayPercent(row)),
                    preview.usageBarsShowUsed ? i18n("used") : i18n("left"));
            }).join(". ");
        }
        function panelProviderToolTipText(provider) {
            return panelMeterDescription(provider);
        }
        function compactTextSegments() {
            if (!preview.previewModel.textVisible) {
                return [];
            }
            var provider = selectedCompactProvider();
            // An empty panel provider selection has no provider to describe;
            // the preview icon stands alone like the live icon fallback.
            if (!provider) {
                return [];
            }
            var segments = [];
            if (false) {
                segments.push({ id: "name", text: provider.title,
                    identifying: ProviderIdentity.providerBrandColorChannels(provider.provider).length !== 3 });
            }
            var metric = preview.metricText(preview.previewModel.textRow);
            if (preview.configPage.cfg_showPercentInPanel && metric.length > 0) {
                segments.push({ id: "usage", text: metric });
            }
            if (preview.configPage.cfg_showCreditsInPanel
                    && typeof provider.credits === "number"
                    && isFinite(provider.credits)) {
                segments.push({ id: "credits",
                    text: i18n("%1cr", provider.credits.toLocaleString(Qt.locale(), "f", 0)) });
            }
            return segments;
        }
        function compactText() {
            return PanelTextFit.fullText(compactTextSegments());
        }
        function displayPercent(row) {
            return preview.usageBarsShowUsed ? row.usedPercent : row.leftPercent;
        }
        function providerIconSource(providerID) {
            var fileName = ProviderIdentity.providerIconFileName(providerID);
            return fileName.length > 0
                ? Qt.resolvedUrl("../../icons/providers/" + fileName)
                : "view-statistics";
        }
        function providerIconIsMask(providerID) {
            return true;
        }
        function providerReadableColor(providerID, background) {
            return ThemeContrast.readableAccentColor(preview.providerColor(providerID), background, Kirigami.Theme.textColor);
        }
        function quotaSeverity(row) {
            if (!preview.showQuotaWarningMarkers || !row) {
                return "";
            }
            var warning = QuotaThresholds.warningPercent(preview.quotaWarningPercent);
            return QuotaThresholds.level(row.usedPercent, warning, QuotaThresholds.criticalPercent(warning, preview.quotaCriticalPercent));
        }
        function statusBadgeColor(severity) {
            return severity === "major" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor;
        }
        function quotaMeterColor(row, accent) {
            var severity = quotaSeverity(row);
            return severity.length > 0 ? statusBadgeColor(severity) : accent;
        }
        function withAlpha(color, alpha) {
            return preview.withAlpha(color, alpha);
        }
    }

    PlainControlsLabel {
        Layout.fillWidth: true
        text: i18n("Panel preview")
        font.bold: true
        elide: Text.ElideRight
    }

    // The outline is the panel: its height is the measured thickness of the
    // real panel (falling back to a typical one), so proportions read true.
    readonly property int panelThickness: {
        var measured = Number(configPage.cfgValue("panelThickness"))
        return isFinite(measured) && measured >= 16 ? Math.round(measured) : Math.round(Kirigami.Units.gridUnit * 2.4)
    }

    // Logo meter stages, left to right: the first selected panel provider
    // (or the selected one) from full quota down to empty.
    readonly property var logoStagePercents: [100, 75, 50, 25, 0]
    readonly property string logoStageProvider: {
        var providers = previewModel.meterProviders || []
        if (providers.length > 0 && providers[0].provider) return String(providers[0].provider)
        if (previewModel.selectedProvider && previewModel.selectedProvider.provider)
            return String(previewModel.selectedProvider.provider)
        var roster = configPage.orderedPanelProviderRoster || []
        return roster.length > 0 && roster[0].provider ? String(roster[0].provider) : ""
    }
    readonly property int logoStageSize: Math.max(12, Math.round(
        Math.max(0, panelThickness - Kirigami.Units.smallSpacing * 2) * previewApplet.panelMeterScale))

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: preview.panelThickness
        radius: 0
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: preview.withAlpha(Kirigami.Theme.textColor, 0.2)
        clip: true
        Accessible.role: Accessible.Graphic
        Accessible.name: i18n("Panel preview")
        Accessible.description: preview.accessibleSummary()

        CompactRepresentation {
            objectName: "panelPreviewRenderer"
            visible: !previewApplet.logoMeters
            anchors.centerIn: parent
            width: Math.max(0, Math.min(implicitWidth, parent.width - Kirigami.Units.smallSpacing * 2))
            height: preview.panelThickness
            applet: previewApplet
            animationsEnabled: false
            interactive: false
            draggable: true
            Accessible.ignored: true
        }

        // Logo meters: one provider's logo at each fill stage, full quota on
        // the left dimming to empty on the right.
        Row {
            objectName: "panelPreviewLogoStages"
            visible: previewApplet.logoMeters && preview.logoStageProvider.length > 0
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing * 2

            Repeater {
                model: previewApplet.logoMeters ? preview.logoStagePercents : []

                delegate: QuotaLogo {
                    required property int modelData
                    providerID: preview.logoStageProvider
                    width: preview.logoStageSize
                    height: preview.logoStageSize
                    animationsEnabled: false
                    iconSource: previewApplet.providerIconSource(providerID)
                    iconIsMask: previewApplet.minimalPanel || previewApplet.providerIconIsMask(providerID)
                    brandColor: previewApplet.minimalPanel ? Kirigami.Theme.textColor
                        : previewApplet.providerReadableColor(providerID, Kirigami.Theme.backgroundColor)
                    meters: [{ percent: modelData, color: brandColor, warning: false }]
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PlainControlsLabel {
            text: i18n("Indicator size")
        }

        Controls.Slider {
            id: meterScaleSlider
            objectName: "panelMeterScaleSlider"
            Layout.fillWidth: true
            from: 0.5
            to: 1
            stepSize: 0.05
            snapMode: Controls.Slider.SnapAlways
            value: Math.min(1, Math.max(0.5, Number(configPage.cfg_panelMeterScale) || 0.75))
            Accessible.name: i18n("Indicator size, share of panel height")
            onMoved: configPage.cfg_panelMeterScale = Math.round(value * 20) / 20
        }

    }

    PlainControlsLabel {
        Layout.fillWidth: true
        text: previewApplet.logoMeters ? i18n("Example: full quota on the left, empty on the right.") : i18n("Example data.")
        wrapMode: Text.WordWrap
        font: Kirigami.Theme.smallFont
        opacity: 0.7
    }
}
