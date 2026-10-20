import QtQuick
import org.kde.kirigami as Kirigami

// Renders the provider logo as a quota meter with a 1px silhouette border
// shifting along the Warm Ivory -> Rust / Burnt Oxide curve (#fbf6e9 ->
// #b8522a -> #4a1f18) and the brand fill dimming toward a warm oxide floor
// as quota depletes.
Item {
    id: logo

    property string providerID: ""
    property var iconSource: ""
    property bool iconIsMask: true
    property color brandColor: Kirigami.Theme.textColor
    // Each entry: { percent: 0..100, color: color, warning: bool }
    property var meters: []
    property bool animationsEnabled: true

    readonly property real targetPercent: {
        if (!meters || meters.length === 0) return 100
        var p0 = Math.max(0, Math.min(100, Number(meters[0].percent) || 0))
        if (meters.length === 1) return p0
        var p1 = Math.max(0, Math.min(100, Number(meters[1].percent) || 0))
        return Math.min(p0, p1)
    }

    property real animatedPercent: targetPercent

    Behavior on animatedPercent {
        enabled: logo.animationsEnabled
        NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
    }

    readonly property real fraction: Math.max(0, Math.min(1, animatedPercent / 100))

    function lerpColor(a, b, t) {
        return Qt.rgba(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t,
            1
        )
    }

    // 3-stop quadratic Bezier color curve (end -> warm mid -> start).
    function curveColor(cEnd, cMid, cStart, t) {
        var u = 1 - t
        return Qt.rgba(
            u * u * cEnd.r + 2 * u * t * cMid.r + t * t * cStart.r,
            u * u * cEnd.g + 2 * u * t * cMid.g + t * t * cStart.g,
            u * u * cEnd.b + 2 * u * t * cMid.b + t * t * cStart.b,
            1
        )
    }

    // Paper White (#f6f3ec) -> Terracotta/Rust mid (#b8522a) -> Burnt Oxide (#4a1f18).
    readonly property color borderColor: curveColor(
        Qt.rgba(0.290, 0.122, 0.094, 1),
        Qt.rgba(0.722, 0.322, 0.165, 1),
        Qt.rgba(0.965, 0.953, 0.925, 1),
        fraction
    )

    readonly property color darkFloor: Qt.rgba(0.22, 0.11, 0.09, 1)
    readonly property color fillColor: lerpColor(darkFloor, brandColor, 0.08 + 0.92 * fraction)

    readonly property var borderOffsets: [
        Qt.point(-1, 0),
        Qt.point(1, 0),
        Qt.point(0, -1),
        Qt.point(0, 1),
        Qt.point(-0.7, -0.7),
        Qt.point(0.7, -0.7),
        Qt.point(-0.7, 0.7),
        Qt.point(0.7, 0.7)
    ]

    Item {
        id: iconBox
        anchors.fill: parent
        anchors.margins: 1

        // 1px silhouette border around the logo.
        Repeater {
            model: logo.borderOffsets

            delegate: Kirigami.Icon {
                required property point modelData
                x: modelData.x
                y: modelData.y
                width: iconBox.width
                height: iconBox.height
                source: logo.iconSource
                fallback: "view-statistics"
                isMask: logo.iconIsMask
                color: logo.borderColor
            }
        }

        // Main brightness-scaled interior fill.
        Kirigami.Icon {
            anchors.fill: parent
            source: logo.iconSource
            fallback: "view-statistics"
            isMask: logo.iconIsMask
            color: logo.fillColor
        }
    }
}
