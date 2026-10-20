import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "../PanelElements.js" as PanelElements
import "../PanelTextFit.js" as PanelTextFit
import "../ThemeContrast.js" as ThemeContrast
import "../ProviderNormalizer.js" as Normalizer

Item {
    id: compactRoot

    required property var applet
    property bool animationsEnabled: true
    property bool interactive: true
    // Local change: meters reorder by drag, in the panel and in the settings
    // preview. The applet applies the drop through reorderPanelProviders().
    property bool draggable: interactive
    property int dragSourceIndex: -1
    property int dragTargetIndex: -1
    property string dragProviderID: ""
    property point dragPointer: Qt.point(0, 0)
    readonly property bool dragging: dragSourceIndex >= 0

    // Insertion slot among the visible meters for a pointer at scene position.
    function dragSlotFor(scenePosition) {
        var grid = metersGridItem
        if (!grid) return -1
        var local = grid.mapFromGlobal(scenePosition.x, scenePosition.y)
        var slot = 0
        for (var i = 0; i < grid.children.length; i++) {
            var child = grid.children[i]
            if (!child || child.objectName !== "panelProviderMeter") continue
            var middle = verticalPanel ? child.y + child.height / 2 : child.x + child.width / 2
            var along = verticalPanel ? local.y : local.x
            if (along > middle) slot = Math.max(slot, child.meterIndex + 1)
        }
        return slot
    }

    function dropDraggedMeter() {
        var from = dragSourceIndex, to = dragTargetIndex, providerID = dragProviderID
        dragSourceIndex = -1; dragTargetIndex = -1; dragProviderID = ""
        if (from < 0 || to < 0 || to === from || to === from + 1) return
        var before = to < meterProviders.length ? meterProviders[to].provider : ""
        applet.reorderPanelProviders(providerID, before)
    }
    property Item metersGridItem: null

    readonly property bool verticalPanel: applet.verticalFormFactor
    readonly property bool minimalStyle: applet.minimalPanel === true
    // Local change: concentric rings (session outer, weekly inner) instead of
    // stacked capsules. Never more than two rings per provider.
    readonly property bool ringMeters: applet.ringMeters === true
    readonly property bool logoMeters: applet.logoMeters === true
    // Local change: logos are optional; meters can stand alone.
    readonly property bool providerIcons: applet.panelProviderIcons !== false && !logoMeters
    // Local change: indicator size as a share of the panel thickness.
    readonly property real meterScale: {
        var value = Number(applet.panelMeterScale)
        return isFinite(value) && value > 0 ? Math.min(1, Math.max(0.5, value)) : 0.75
    }
    readonly property var meterProviders: applet.compactProviders()
    readonly property bool hasProviderMeters: meterProviders.length > 0
    readonly property var incidentProvider: applet.providerPresentation(applet.primaryIncidentProvider())
    // The incident dot must sit on the incident provider's own icon. The
    // standalone status element stays only when no rendered meter, and no
    // vertical identity icon, can carry the badge.
    readonly property bool incidentProviderHasMeterBadge: incidentProvider !== null
        && meterProviders.some(function(provider) {
            return provider.provider === incidentProvider.provider
                && provider.hasIncident === true
                && provider.statusKnown !== false
        })
    // Panel text competes with the meter row for a bounded width. Rather than
    // eliding one composed string into a fragment, the renderer measures every
    // composition PanelTextFit offers and shows the widest one that fits. The
    // full composition stays in fullText for tooltips and accessible names.
    readonly property var textCompositions: PanelTextFit.texts(
        PanelTextFit.compositions(applet.compactTextSegments()))
    readonly property var textCompositionWidths: [
        Math.ceil(firstCompositionMeasurer.implicitWidth),
        Math.ceil(secondCompositionMeasurer.implicitWidth),
        Math.ceil(thirdCompositionMeasurer.implicitWidth)
    ].slice(0, textCompositions.length)
    readonly property string fullText: textCompositions.length > 0 ? textCompositions[0] : ""
    // What the row spends before any text, so the budget offers the label every
    // pixel the panel actually has. A flat allowance either surrenders segments
    // that would have fitted or overruns the maximum and clips the row.
    // Both slots are computed from the meter row alone: deriving them from the
    // rendered text would feed the chosen composition back into its own budget.
    readonly property int statusSlotWidth: statusElementVisible
        ? Math.ceil(Kirigami.Units.smallSpacing * 1.5) + Kirigami.Units.smallSpacing : 0
    readonly property int meterRowWidth: hasProviderMeters
        ? meterProviders.length * meterWidth
            + Math.max(0, meterProviders.length - 1) * Kirigami.Units.smallSpacing
        : 0
    // A superset of showPrimaryIdentity: reserving the icon slot while it turns
    // out hidden costs the label a few pixels, never a clipped row.
    readonly property bool standaloneIdentityVisible: !hasProviderMeters
        || (!verticalPanel && (meterProviders.length > 1 || !selectedProviderHasMeter))
    readonly property int textSlotOffset: Kirigami.Units.smallSpacing * 2
        + statusSlotWidth + meterRowWidth
    // Inline text sits inside the selected meter, one meter spacing after its
    // capsules, so that gap always exists. The standalone element stands in its
    // own layout cell and pays a gap per neighbour it actually has: the layout
    // skips hidden elements, so hiding the meters removes that gap with them.
    readonly property int inlineTextBudget: Math.max(0,
        maximumCompactWidth - textSlotOffset - meterSpacing)
    readonly property int standaloneTextBudget: Math.max(0,
        maximumCompactWidth - textSlotOffset
            - (hasProviderMeters ? Kirigami.Units.smallSpacing : 0)
            - (standaloneIdentityVisible
                ? Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing : 0))
    readonly property int inlineTextIndex: PanelTextFit.fittedIndex(textCompositionWidths, inlineTextBudget)
    readonly property int textCompositionIndex: inlinePrimaryText
        ? inlineTextIndex
        : PanelTextFit.fittedIndex(textCompositionWidths, standaloneTextBudget)
    // The chosen index and the arrays it indexes are separate bindings, so a
    // configuration change can re-evaluate one before the other and leave the
    // index pointing past a list that has already shrunk. Read through these
    // instead of indexing directly: an intermediate frame must fall back to no
    // text, never assign undefined to the rendered width.
    readonly property string primaryText: compositionText(textCompositionIndex)
    readonly property int primaryTextWidth: compositionWidth(textCompositionIndex)
    readonly property var selectedProvider: applet.selectedCompactProvider()
    readonly property bool selectedProviderHasMeter: selectedProvider !== null && selectedProvider !== undefined
        && meterProviders.some(function(provider) { return provider.provider === selectedProvider.provider })
    // Without rendered meters in a vertical panel the identity icon is the only
    // anchor, so it carries the badge only when the primary incident belongs to
    // the selected provider. Any other incident keeps the standalone status
    // element available so the outage never loses its marker.
    readonly property bool identityCarriesIncidentBadge: verticalPanel
        && !hasProviderMeters
        && incidentProvider !== null
        && selectedProvider !== null && selectedProvider !== undefined
        && incidentProvider.provider === selectedProvider.provider
    // Local change: provider status is not supported; no status element or badge.
    readonly property bool statusElementVisible: false
    // Independent text still needs its identity when several meters are shown.
    readonly property bool inlinePrimaryText: !verticalPanel && fullText.length > 0
        && inlineTextWidth > 0
        && applet.panelElementOrder().join(",") === PanelElements.defaultOrder.join(",")
        && selectedProviderHasMeter
    readonly property bool showPrimaryIdentity: providerIcons && (!hasProviderMeters
        || (!verticalPanel && primaryText.length > 0 && !inlinePrimaryText
            && (meterProviders.length > 1 || !selectedProviderHasMeter)))
    readonly property int compactExtent: Kirigami.Units.iconSizes.smallMedium
        + Kirigami.Units.smallSpacing * 2
    readonly property int meterContentHeight: Math.max(0, height - Kirigami.Units.smallSpacing * 2)
    // The indicator's extent along the panel's thickness after scaling.
    readonly property int meterExtent: Math.max(12, Math.round(
        (verticalPanel ? Math.max(0, width - Kirigami.Units.smallSpacing * 2) : meterContentHeight) * meterScale))
    readonly property int meterIconSize: Math.max(12, Math.round(meterExtent * 0.85))
    readonly property int meterSpacing: Kirigami.Units.smallSpacing
    // Minimum share of chroma removed from a capsule whose brand hue
    // resembles a warning color. ThemeContrast.chromaReduction raises it for
    // very saturated brands so what remains carries no hue to confuse.
    readonly property real mutedMeterChromaReduction: 0.75
    readonly property int meterBarHeight: Math.max(2, Math.min(8, Math.round(meterExtent / 4)))
    // Rings fill the panel thickness; in vertical panels they take the icon slot size.
    readonly property int ringSize: meterExtent
    // Capsules keep a ~3:1 shape as they grow; rings and logo meters stay square.
    readonly property int meterBarWidth: ringMeters || logoMeters ? ringSize : verticalPanel
        ? Math.max(8, Math.min(Math.round(meterExtent * 1.25), width - meterIconSize - meterSpacing * 3))
        : Math.round(meterExtent * 1.25)
    readonly property int meterWidth: (providerIcons ? meterIconSize + meterSpacing : 0) + meterBarWidth
        + (verticalPanel ? 0 : meterSpacing)
    readonly property int meterHeight: Math.max(compactExtent, ringMeters || logoMeters
        ? ringSize + meterSpacing * 2 : meterBarHeight * 2 + meterSpacing * 3)
    readonly property int metersExtent: meterProviders.length * meterHeight
        + Math.max(0, meterProviders.length - 1) * meterSpacing
    // Local change: grow past 18 grid units when the meter row alone needs
    // more, keeping a few units of text budget beside it. textSlotOffset only
    // depends on meter geometry, never on this width, so no binding loop.
    readonly property int maximumCompactWidth: Math.max(Kirigami.Units.gridUnit * 18,
        textSlotOffset + Kirigami.Units.gridUnit * 4)
    readonly property int inlineTextWidth: Math.min(compositionWidth(inlineTextIndex),
        inlineTextBudget)
    readonly property int desiredWidth: verticalPanel
        ? Kirigami.Units.iconSizes.small + Kirigami.Units.iconSizes.smallMedium + meterSpacing * 4
        : Math.min(maximumCompactWidth, Math.max(Kirigami.Units.gridUnit * 4.8,
            compactRow.implicitWidth + Kirigami.Units.smallSpacing * 2))
    readonly property int desiredHeight: verticalPanel
        ? Math.ceil(compactRow.implicitHeight + Kirigami.Units.smallSpacing * 2)
        : compactExtent

    Layout.minimumWidth: verticalPanel
        ? (hasProviderMeters ? Kirigami.Units.iconSizes.small * 2 : compactExtent) : desiredWidth
    Layout.preferredWidth: desiredWidth
    Layout.maximumWidth: verticalPanel ? Infinity : desiredWidth
    Layout.fillWidth: verticalPanel
    Layout.minimumHeight: verticalPanel ? desiredHeight : 0
    Layout.preferredHeight: desiredHeight
    Layout.maximumHeight: verticalPanel ? desiredHeight : Infinity

    implicitWidth: desiredWidth
    implicitHeight: desiredHeight
    clip: true

    // Visibility rules can filter a hovered meter out while its provider
    // stays in the roster. Its destroyed MouseArea delivers no reliable
    // hover-exit, so drop the stale hover here instead of letting the tooltip
    // stay narrowed to a meter that is no longer rendered. The empty-string
    // default keeps the settings preview (which has no hover state and never
    // sets one outside interactive mode) a no-op.
    onMeterProvidersChanged: {
        var hovered = String(compactRoot.applet.hoveredPanelProviderID || "")
        if (hovered.length > 0 && !meterProviders.some(function(meter) {
                return meter && meter.provider === hovered
            })) {
            compactRoot.applet.clearHoveredPanelProvider(hovered)
        }
    }

    function compositionText(index) {
        var text = textCompositions[index]
        return typeof text === "string" ? text : ""
    }

    function compositionWidth(index) {
        var width = textCompositionWidths[index]
        return typeof width === "number" && isFinite(width) && width > 0 ? width : 0
    }

    MouseArea {
        id: compactBackgroundMouse
        anchors.fill: parent
        enabled: compactRoot.interactive
        cursorShape: Qt.PointingHandCursor
        onClicked: compactRoot.applet.expanded = !compactRoot.applet.expanded
    }

    // Measure outside the Loader so its layout-assigned width cannot feed back
    // into the label's preferred width and collapse the compact representation.
    // Every candidate composition gets its own measurer, so choosing one cannot
    // feed its own width back into the choice. There are at most three: the
    // full composition and one per surrendered segment. These are the same
    // label type the panel renders, because shaped label widths and raw font
    // metrics disagree by a fraction of a pixel and a composition measured a
    // pixel short is elided by the renderer that was asked to make it fit.
    PlainPlasmaLabel {
        id: firstCompositionMeasurer

        visible: false
        font.bold: !compactRoot.minimalStyle
        text: compactRoot.textCompositions.length > 0 ? compactRoot.textCompositions[0] : ""
    }

    PlainPlasmaLabel {
        id: secondCompositionMeasurer

        visible: false
        font.bold: !compactRoot.minimalStyle
        text: compactRoot.textCompositions.length > 1 ? compactRoot.textCompositions[1] : ""
    }

    PlainPlasmaLabel {
        id: thirdCompositionMeasurer

        visible: false
        font.bold: !compactRoot.minimalStyle
        text: compactRoot.textCompositions.length > 2 ? compactRoot.textCompositions[2] : ""
    }

    GridLayout {
        id: compactRow

        columns: compactRoot.verticalPanel ? 1 : -1
        rows: compactRoot.verticalPanel ? -1 : 1

        // The applet keeps a minimum panel width, so a short content set (meters
        // without panel text) leaves spare room. Centre the row instead of
        // letting all of it pile up on the right of the content.
        anchors.centerIn: parent
        width: Math.max(0, Math.min(compactRoot.width - Kirigami.Units.smallSpacing * 2,
            implicitWidth))
        height: compactRoot.verticalPanel ? implicitHeight
            : Math.max(0, compactRoot.height - Kirigami.Units.smallSpacing * 2)
        rowSpacing: Kirigami.Units.smallSpacing
        columnSpacing: Kirigami.Units.smallSpacing

        Repeater {
            model: compactRoot.applet.panelElementOrder()

            delegate: Loader {
                id: elementLoader

                required property var modelData

                readonly property bool isTextElement: modelData === "text"
                readonly property bool elementVisible: modelData === "identity"
                    ? compactRoot.showPrimaryIdentity
                    : (modelData === "status"
                    ? compactRoot.statusElementVisible
                    : (modelData === "text"
                    ? (!compactRoot.verticalPanel && compactRoot.primaryText.length > 0 && !compactRoot.inlinePrimaryText)
                    : compactRoot.hasProviderMeters))

                sourceComponent: modelData === "identity"
                    ? identityElement
                    : (modelData === "status"
                    ? statusElement
                    : (modelData === "text" ? textElement : metersElement))
                visible: elementVisible
                Layout.fillWidth: isTextElement && elementVisible
                Layout.preferredWidth: !elementVisible
                    ? 0
                    : (modelData === "identity"
                    ? Kirigami.Units.iconSizes.smallMedium
                    : (modelData === "status"
                    ? Kirigami.Units.smallSpacing * 1.5
                    : (modelData === "meters"
                    ? (compactRoot.verticalPanel ? compactRoot.meterWidth
                        : compactRoot.meterProviders.length * compactRoot.meterWidth
                            + (compactRoot.inlinePrimaryText ? compactRoot.inlineTextWidth + compactRoot.meterSpacing : 0)
                            + Math.max(0, compactRoot.meterProviders.length - 1) * Kirigami.Units.smallSpacing)
                    : Math.max(Kirigami.Units.gridUnit * 2, compactRoot.primaryTextWidth))))
                Layout.preferredHeight: compactRoot.verticalPanel
                    ? (modelData === "meters" ? compactRoot.metersExtent
                        : (modelData === "status" ? Kirigami.Units.smallSpacing * 1.5 : compactRoot.compactExtent))
                    : compactRow.height
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }

    Component {
        id: identityElement

        Item {
            id: compactIdentity

            function activate() {
                if (!compactRoot.interactive) {
                    return
                }
                if (compactRoot.selectedProvider) {
                    compactRoot.applet.openProviderFromPanel(compactRoot.selectedProvider.provider)
                } else {
                    compactRoot.applet.expanded = !compactRoot.applet.expanded
                }
            }

            activeFocusOnTab: compactRoot.interactive && visible
            Accessible.role: compactRoot.interactive ? Accessible.Button : Accessible.Graphic
            Accessible.name: compactRoot.selectedProvider
                ? i18n("Open %1", compactRoot.selectedProvider.title) : "LucenBar Lite"
            Accessible.ignored: !compactRoot.interactive
            Accessible.onPressAction: activate()

            Keys.onPressed: function(event) {
                switch (event.key) {
                case Qt.Key_Space:
                case Qt.Key_Enter:
                case Qt.Key_Return:
                case Qt.Key_Select:
                    compactIdentity.activate()
                    event.accepted = true
                    break
                }
            }

            MouseArea {
                anchors.fill: parent
                enabled: compactRoot.interactive
                cursorShape: Qt.PointingHandCursor
                onClicked: compactIdentity.activate()
            }

            // Keyboard users get the same focus ring the provider meters draw,
            // so the standalone icon shows when it is the active control.
            Rectangle {
                objectName: "panelIdentityFocusBorder"

                anchors.fill: parent
                visible: compactIdentity.activeFocus && compactRoot.interactive
                radius: Kirigami.Units.smallSpacing
                color: "transparent"
                border.width: 1
                border.color: Kirigami.Theme.focusColor
            }

            readonly property string compactProvider: compactRoot.applet.selectedCompactProvider()
                ? compactRoot.applet.selectedCompactProvider().provider
                : "codex"

            visible: compactRoot.showPrimaryIdentity
            implicitWidth: Kirigami.Units.iconSizes.smallMedium
            implicitHeight: Kirigami.Units.iconSizes.smallMedium

            Kirigami.Icon {
                id: compactIdentityIcon
                objectName: "panelIdentityIcon"

                anchors.fill: parent
                source: compactRoot.applet.loading ? "view-refresh" : compactRoot.applet.providerIconSource(parent.compactProvider)
                fallback: "view-statistics"
                isMask: !compactRoot.applet.loading && (compactRoot.minimalStyle || compactRoot.applet.providerIconIsMask(parent.compactProvider))
                color: compactRoot.applet.loading || compactRoot.minimalStyle
                    ? Kirigami.Theme.textColor
                    : compactRoot.applet.providerReadableColor(parent.compactProvider, Kirigami.Theme.backgroundColor)

                RotationAnimator {
                    target: compactIdentityIcon
                    running: compactRoot.animationsEnabled && compactRoot.applet.loading && Kirigami.Units.longDuration > 0
                    from: 0
                    to: 360
                    duration: 1250
                    loops: Animation.Infinite
                    onStopped: compactIdentityIcon.rotation = 0
                }

                Rectangle {
                    id: compactVerticalStatusBadge
                    objectName: "panelIdentityBadge"

                    // Without meters this icon is the only anchor, so it may
                    // carry the badge only for its own provider's incident.
                    // Loading replaces the icon with a refresh spinner, so the
                    // badge waits for the provider icon to come back.
                    visible: compactRoot.identityCarriesIncidentBadge
                        && !compactRoot.applet.loading
                    anchors.top: parent.top
                    anchors.right: parent.right
                    width: Math.round(Kirigami.Units.iconSizes.smallMedium / 3)
                    height: width
                    radius: width / 2
                    color: compactRoot.selectedProvider
                        ? compactRoot.applet.statusBadgeColor(compactRoot.selectedProvider.statusSeverity)
                        : "transparent"
                    border.width: 1
                    border.color: Kirigami.Theme.backgroundColor
                }
            }
        }
    }

    Component {
        id: statusElement

        Item {
            id: compactStatusBadge

            visible: compactRoot.statusElementVisible
            implicitWidth: Kirigami.Units.smallSpacing * 1.5
            implicitHeight: implicitWidth

            // The Loader gives this item the full panel row height. Keep the
            // status dot square inside it instead of stretching into a pill.
            Rectangle {
                id: panelStatusDot
                objectName: "panelStatusDot"

                anchors.centerIn: parent
                width: parent.implicitWidth
                height: width
                radius: width / 2
                color: compactRoot.incidentProvider
                    ? compactRoot.applet.statusBadgeColor(compactRoot.incidentProvider.statusSeverity)
                    : "transparent"
                border.width: 1
                border.color: Kirigami.Theme.backgroundColor

                PlainToolTip {
                    visible: compactStatusMouse.containsMouse
                    plainText: compactRoot.incidentProvider
                        ? i18n("%1: %2", compactRoot.incidentProvider.title, compactRoot.incidentProvider.status)
                        : ""
                }
            }

            MouseArea {
                id: compactStatusMouse

                anchors.fill: parent
                enabled: compactRoot.interactive
                hoverEnabled: true
                // A binding avoids Qt rejecting a bare zero enum literal.
                acceptedButtons: (0)
            }
        }
    }

    Component {
        id: textElement

        PlainPlasmaLabel {
            objectName: "panelStandaloneText"
            visible: !compactRoot.verticalPanel && compactRoot.primaryText.length > 0
            text: compactRoot.primaryText
            Accessible.name: compactRoot.fullText
            elide: Text.ElideRight
            font.bold: !compactRoot.minimalStyle
            // The loader stretches this label to the full row height, so the
            // default top alignment would sit the text above the centred
            // provider icon beside it.
            verticalAlignment: Text.AlignVCenter
        }
    }

    Component {
        id: metersElement

        GridLayout {
            id: metersGrid
            columns: compactRoot.verticalPanel ? 1 : -1
            rows: compactRoot.verticalPanel ? -1 : 1
            rowSpacing: compactRoot.meterSpacing
            columnSpacing: compactRoot.meterSpacing
            Component.onCompleted: compactRoot.metersGridItem = metersGrid
            Component.onDestruction: if (compactRoot.metersGridItem === metersGrid) compactRoot.metersGridItem = null

            // Insertion marker while a meter is dragged.
            Rectangle {
                visible: compactRoot.dragging && compactRoot.dragTargetIndex >= 0
                z: 5
                color: Kirigami.Theme.highlightColor
                radius: 1
                width: compactRoot.verticalPanel ? metersGrid.width : 2
                height: compactRoot.verticalPanel ? 2 : metersGrid.height
                x: {
                    if (compactRoot.verticalPanel) return 0
                    var slot = compactRoot.dragTargetIndex, edge = 0
                    for (var i = 0; i < metersGrid.children.length; i++) {
                        var child = metersGrid.children[i]
                        if (!child || child.objectName !== "panelProviderMeter") continue
                        if (child.meterIndex === slot) return child.x - compactRoot.meterSpacing / 2 - 1
                        if (child.meterIndex === slot - 1) edge = child.x + child.width + compactRoot.meterSpacing / 2 - 1
                    }
                    return edge
                }
                y: {
                    if (!compactRoot.verticalPanel) return 0
                    var slot = compactRoot.dragTargetIndex, edge = 0
                    for (var i = 0; i < metersGrid.children.length; i++) {
                        var child = metersGrid.children[i]
                        if (!child || child.objectName !== "panelProviderMeter") continue
                        if (child.meterIndex === slot) return child.y - compactRoot.meterSpacing / 2 - 1
                        if (child.meterIndex === slot - 1) edge = child.y + child.height + compactRoot.meterSpacing / 2 - 1
                    }
                    return edge
                }
            }

            Repeater {
                id: metersRepeater
                model: compactRoot.meterProviders

                delegate: Item {
                    id: compactMeter
                    objectName: "panelProviderMeter"

                    required property var modelData
                    required property int index
                    readonly property int meterIndex: index
                    readonly property bool beingDragged: compactRoot.dragging && compactRoot.dragSourceIndex === index
                    opacity: beingDragged ? 0.35 : 1

                    DragHandler {
                        id: meterDrag
                        enabled: compactRoot.draggable
                        target: null
                        dragThreshold: 6
                        onActiveChanged: {
                            if (active) {
                                compactRoot.dragSourceIndex = compactMeter.index
                                compactRoot.dragProviderID = compactMeter.modelData.provider
                                compactRoot.dragTargetIndex = compactRoot.dragSlotFor(centroid.scenePosition)
                                compactRoot.dragPointer = compactRoot.mapFromGlobal(centroid.scenePosition.x, centroid.scenePosition.y)
                            } else {
                                compactRoot.dropDraggedMeter()
                            }
                        }
                        onCentroidChanged: {
                            if (!active) return
                            compactRoot.dragTargetIndex = compactRoot.dragSlotFor(centroid.scenePosition)
                            compactRoot.dragPointer = compactRoot.mapFromGlobal(centroid.scenePosition.x, centroid.scenePosition.y)
                        }
                    }
                    readonly property bool showsPrimaryText: compactRoot.inlinePrimaryText
                        && modelData.provider === compactRoot.selectedProvider.provider
                    readonly property var quotaRows: compactRoot.applet.panelMeterRows(modelData)
                    readonly property color accent: compactRoot.minimalStyle ? Kirigami.Theme.textColor
                        : compactRoot.applet.providerReadableColor(modelData.provider, Kirigami.Theme.backgroundColor)
                    // Capsules carry no text, so a brand hue close to the warning or
                    // critical color would read as an alert. Such capsules use a muted
                    // brand color; the icon keeps the full brand color. Minimal style
                    // keeps capsules in the theme text color, so it is never muted.
                    readonly property real meterChromaShare: Math.max(
                        compactRoot.mutedMeterChromaReduction, ThemeContrast.chromaReduction(accent))
                    readonly property color meterAccent: compactRoot.minimalStyle ? accent
                        : ThemeContrast.distinctAccentColor(accent,
                            [compactRoot.applet.statusBadgeColor("major"), compactRoot.applet.statusBadgeColor("minor")],
                            ThemeContrast.mutedAccentColor(accent, meterChromaShare,
                                Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor))

                    function activate() {
                        if (!compactRoot.interactive) {
                            return
                        }
                        compactRoot.applet.openProviderFromPanel(compactMeter.modelData.provider)
                    }

                    Layout.preferredWidth: compactRoot.meterWidth
                        + (showsPrimaryText ? compactRoot.inlineTextWidth + compactRoot.meterSpacing : 0)
                    Layout.preferredHeight: compactRoot.verticalPanel ? compactRoot.meterHeight : compactRow.height
                    activeFocusOnTab: compactRoot.interactive

                    Accessible.role: compactRoot.interactive ? Accessible.Button : Accessible.Graphic
                    Accessible.name: compactRoot.interactive ? i18n("Open %1", modelData.title) : modelData.title
                    Accessible.description: compactRoot.applet.panelProviderToolTipText(modelData)
                        + (showsPrimaryText ? ". " + compactRoot.fullText : "")
                    Accessible.ignored: !compactRoot.interactive
                    Accessible.onPressAction: compactMeter.activate()

                    Keys.onPressed: function(event) {
                        switch (event.key) {
                        case Qt.Key_Space:
                        case Qt.Key_Enter:
                        case Qt.Key_Return:
                        case Qt.Key_Select:
                            compactMeter.activate()
                            event.accepted = true
                            break
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: Kirigami.Units.smallSpacing
                        color: compactRoot.applet.withAlpha(Kirigami.Theme.textColor,
                            compactMeterMouse.pressed ? 0.14 : (compactMeterMouse.containsMouse ? 0.07 : 0))

                        Behavior on color {
                            ColorAnimation {
                                duration: Kirigami.Units.shortDuration
                            }
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        visible: compactMeter.activeFocus
                        radius: Kirigami.Units.smallSpacing
                        color: "transparent"
                        border.width: 1
                        border.color: Kirigami.Theme.focusColor
                    }

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: compactRoot.meterSpacing
                        opacity: compactMeter.modelData.usageStale === true ? 0.55 : 1

                        Kirigami.Icon {
                            objectName: "panelProviderIcon"
                            visible: compactRoot.providerIcons
                            source: compactRoot.applet.providerIconSource(compactMeter.modelData.provider)
                            fallback: "view-statistics"
                            isMask: compactRoot.minimalStyle || compactRoot.applet.providerIconIsMask(compactMeter.modelData.provider)
                            color: compactMeter.accent
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: compactRoot.meterIconSize
                            Layout.preferredHeight: compactRoot.meterIconSize

                            PlainPlasmaLabel {
                                objectName: "panelConfidenceMarker"
                                visible: text.length > 0
                                anchors.bottom: parent.bottom
                                anchors.right: parent.right
                                text: {
                                    var confidence = compactMeter.quotaRows.map(function(row) {
                                        return Normalizer.usageConfidence(row.dataConfidence)
                                    })
                                    return confidence.indexOf("unknown") >= 0 ? "?"
                                        : confidence.indexOf("estimated") >= 0 ? "~" : ""
                                }
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                font.bold: true
                                color: Kirigami.Theme.textColor
                                Rectangle {
                                    anchors.fill: parent
                                    z: -1
                                    radius: Kirigami.Units.smallSpacing / 2
                                    color: Kirigami.Theme.backgroundColor
                                }
                            }

                            Rectangle {
                                id: meterIncidentBadge
                                objectName: "panelIncidentBadge"

                                // Refreshes keep the rendered providers, so the
                                // badge must not flicker away with loading.
                                visible: false
                                anchors.top: parent.top
                                anchors.right: parent.right
                                width: Math.max(4, Math.round(compactRoot.meterIconSize / 3))
                                height: width
                                radius: width / 2
                                color: compactRoot.applet.statusBadgeColor(compactMeter.modelData.statusSeverity)
                                border.width: 1
                                border.color: Kirigami.Theme.backgroundColor
                            }
                        }

                        QuotaRings {
                            objectName: "panelMeterRings"
                            visible: compactRoot.ringMeters
                            animationsEnabled: compactRoot.animationsEnabled
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: compactRoot.ringSize
                            Layout.preferredHeight: compactRoot.ringSize
                            meters: visible ? compactMeter.quotaRows.slice(0, 2).map(function(row) {
                                return {
                                    percent: compactRoot.applet.displayPercent(row),
                                    color: compactRoot.applet.quotaMeterColor(row, compactMeter.meterAccent),
                                    warning: compactRoot.applet.quotaSeverity(row).length > 0
                                }
                            }) : []
                        }

                        QuotaLogo {
                            objectName: "panelMeterLogo"
                            visible: compactRoot.logoMeters
                            animationsEnabled: compactRoot.animationsEnabled
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: compactRoot.ringSize
                            Layout.preferredHeight: compactRoot.ringSize
                            providerID: compactMeter.modelData.provider
                            iconSource: compactRoot.applet.providerIconSource(compactMeter.modelData.provider)
                            iconIsMask: compactRoot.minimalStyle || compactRoot.applet.providerIconIsMask(compactMeter.modelData.provider)
                            brandColor: compactMeter.accent
                            meters: visible ? compactMeter.quotaRows.slice(0, 2).map(function(row) {
                                return {
                                    percent: compactRoot.applet.displayPercent(row),
                                    color: compactRoot.applet.quotaMeterColor(row, compactMeter.accent),
                                    warning: compactRoot.applet.quotaSeverity(row).length > 0
                                }
                            }) : []
                        }

                        ColumnLayout {
                            spacing: compactRoot.meterSpacing
                            visible: !compactRoot.ringMeters && !compactRoot.logoMeters
                            Layout.alignment: Qt.AlignVCenter

                            Repeater {
                                model: compactRoot.ringMeters || compactRoot.logoMeters ? [] : compactMeter.quotaRows

                                delegate: Rectangle {
                                    id: quotaCapsule
                                    required property var modelData
                                    readonly property real meter: compactRoot.applet.displayPercent(modelData)
                                    readonly property color meterColor: compactRoot.applet.quotaMeterColor(modelData, compactMeter.meterAccent)
                                    readonly property bool warning: compactRoot.applet.quotaSeverity(modelData).length > 0

                                    objectName: "panelMeterTrack"
                                    Layout.preferredWidth: compactRoot.meterBarWidth
                                    Layout.preferredHeight: compactRoot.meterBarHeight
                                    radius: height / 2
                                    // The track remains identifiable at zero, including an
                                    // exhausted quota when displaying the remaining amount.
                                    color: compactRoot.applet.withAlpha(meterColor, warning ? 0.32 : 0.18)
                                    border.width: warning || meter === 0 ? 1 : 0
                                    border.color: compactRoot.applet.withAlpha(meterColor, warning ? 0.9 : 0.45)
                                    clip: true

                                    Rectangle {
                                        objectName: "panelMeterFill"
                                        // Any amount above zero stays visible as at least a
                                        // round dot, like the popup meters; zero stays empty.
                                        width: quotaCapsule.meter > 0
                                            ? Math.max(parent.height, parent.width * Math.min(100, quotaCapsule.meter) / 100)
                                            : 0
                                        height: parent.height
                                        radius: Math.min(height / 2, width / 2)
                                        color: quotaCapsule.meterColor

                                        // Every popup meter grows into a new
                                        // reading; this capsule jumped to it.
                                        // The settings preview renders static
                                        // frames, so it opts out.
                                        Behavior on width {
                                            enabled: compactRoot.animationsEnabled

                                            NumberAnimation {
                                                duration: Kirigami.Units.longDuration
                                                easing.type: Easing.OutCubic
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        PlainPlasmaLabel {
                            objectName: "panelProviderText"
                            visible: compactMeter.showsPrimaryText
                            text: visible ? compactRoot.primaryText : ""
                            // Surrendered segments stay available to assistive
                            // technology even when the panel has no room.
                            Accessible.name: compactRoot.fullText
                            Layout.preferredWidth: compactRoot.inlineTextWidth
                            Layout.maximumWidth: compactRoot.inlineTextWidth
                            Layout.alignment: Qt.AlignVCenter
                            elide: Text.ElideRight
                            font.bold: !compactRoot.minimalStyle
                        }
                    }

                    MouseArea {
                        id: compactMeterMouse

                        anchors.fill: parent
                        enabled: compactRoot.interactive
                        z: 1
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: compactMeter.activate()
                        // The plasmoid tooltip narrows to the hovered meter, so
                        // each panel icon reports only its own provider. Clearing
                        // only the matching id keeps a fast move between two
                        // meters from ending on an empty tooltip.
                        onContainsMouseChanged: {
                            if (!compactRoot.interactive) {
                                return
                            }
                            if (containsMouse) {
                                compactRoot.applet.setHoveredPanelProvider(compactMeter.modelData.provider)
                            } else {
                                compactRoot.applet.clearHoveredPanelProvider(compactMeter.modelData.provider)
                            }
                        }
                    }
                }
            }
        }
    }

    // The dragged meter's logo follows the pointer.
    Kirigami.Icon {
        visible: compactRoot.dragging
        z: 100
        source: compactRoot.dragging ? compactRoot.applet.providerIconSource(compactRoot.dragProviderID) : ""
        fallback: "view-statistics"
        isMask: compactRoot.dragging && compactRoot.applet.providerIconIsMask(compactRoot.dragProviderID)
        color: compactRoot.dragging ? compactRoot.applet.providerReadableColor(compactRoot.dragProviderID, Kirigami.Theme.backgroundColor) : Kirigami.Theme.textColor
        width: Kirigami.Units.iconSizes.smallMedium
        height: Kirigami.Units.iconSizes.smallMedium
        x: compactRoot.dragPointer.x - width / 2
        y: compactRoot.dragPointer.y - height / 2
        opacity: 0.9
    }
}
