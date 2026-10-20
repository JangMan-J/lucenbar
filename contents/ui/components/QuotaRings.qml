pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import org.kde.kirigami as Kirigami

// Up to two segmented quota rings: the outer ring is the first quota row
// (session), the inner ring the second (weekly). A missing row draws no
// track, so a provider with one window shows a single ring.
Item {
    id: rings

    // Each entry: { percent: 0..100, color: color, warning: bool }
    property var meters: []
    property bool animationsEnabled: true

    readonly property int ringCount: Math.min(2, meters.length)
    readonly property int segmentCount: 5
    readonly property real segmentStep: 360 / segmentCount
    readonly property real segmentGap: 8
    readonly property real segmentSweep: segmentStep - segmentGap
    // Keep the inner ring and its gaps legible at the panel's 12px minimum.
    readonly property real ringWidth: Math.max(1.25, Math.min(width, height) / 9)
    readonly property real ringGap: Math.max(1, ringWidth * 0.6)
    readonly property real outerRadius: (Math.min(width, height) - ringWidth) / 2
    readonly property real innerRadius: outerRadius - ringWidth - ringGap

    function meterAt(index) {
        return index < meters.length ? meters[index] : null
    }
    function percentAt(index) {
        var meter = meterAt(index)
        return meter ? Math.max(0, Math.min(100, Number(meter.percent) || 0)) : 0
    }
    function colorAt(index) {
        var meter = meterAt(index)
        return meter ? meter.color : Kirigami.Theme.textColor
    }
    function trackAlphaAt(index) {
        var meter = meterAt(index)
        return meter && meter.warning ? 0.32 : 0.18
    }

    Repeater {
        model: rings.ringCount

        delegate: Item {
            id: ring
            required property int index
            anchors.fill: parent

            readonly property real radius: Math.max(0,
                index === 0 ? rings.outerRadius : rings.innerRadius)
            readonly property color meterColor: rings.colorAt(index)
            readonly property real trackAlpha: rings.trackAlphaAt(index)
            property real percent: rings.percentAt(index)
            visible: radius > rings.ringWidth / 2

            // Animate the quota once, so crossing a segment boundary does not
            // make several independent segment animations race each other.
            Behavior on percent {
                enabled: rings.animationsEnabled
                NumberAnimation { duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
            }

            Repeater {
                model: rings.segmentCount

                delegate: Shape {
                    id: segment
                    required property int index
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer

                    readonly property real angle: -90 + rings.segmentGap / 2
                        + index * rings.segmentStep
                    // A partial segment retains the exact quota; do not round
                    // readings to 20% steps. Flat caps keep the gaps open and
                    // avoid a bright round dot at zero.
                    readonly property real filledSweep: rings.segmentSweep
                        * Math.max(0, Math.min(1, ring.percent * rings.segmentCount / 100 - index))

                    ShapePath {
                        strokeColor: Qt.alpha(ring.meterColor, ring.trackAlpha)
                        fillColor: "transparent"
                        strokeWidth: rings.ringWidth
                        capStyle: ShapePath.FlatCap
                        PathAngleArc {
                            centerX: rings.width / 2
                            centerY: rings.height / 2
                            radiusX: ring.radius
                            radiusY: ring.radius
                            startAngle: segment.angle
                            sweepAngle: rings.segmentSweep
                        }
                    }

                    ShapePath {
                        strokeColor: segment.filledSweep > 0 ? ring.meterColor : "transparent"
                        fillColor: "transparent"
                        strokeWidth: rings.ringWidth
                        capStyle: ShapePath.FlatCap
                        PathAngleArc {
                            centerX: rings.width / 2
                            centerY: rings.height / 2
                            radiusX: ring.radius
                            radiusY: ring.radius
                            startAngle: segment.angle
                            sweepAngle: segment.filledSweep
                        }
                    }
                }
            }
        }
    }
}
