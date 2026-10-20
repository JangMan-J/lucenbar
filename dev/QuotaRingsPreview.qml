pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import "../contents/ui/components"

Window {
    id: preview
    width: 960
    height: 600
    visible: true
    title: "LucenBar segmented quota rings"
    property string outputPath: {
        var args = Qt.application.arguments
        var marker = args.indexOf("--")
        return marker >= 0 && marker + 1 < args.length ? args[marker + 1] : ""
    }

    Rectangle {
        id: sheet
        anchors.fill: parent
        color: "#22272b"

        Repeater {
            model: 2
            delegate: Rectangle {
                id: theme
                required property int index
                y: index * 300
                width: sheet.width
                height: 300
                color: index === 0 ? "#22272b" : "#f5f6f7"
                readonly property color ink: index === 0 ? "#eff0f1" : "#232629"
                Text {
                    x: 24; y: 16
                    text: "Segmented rings · " + (theme.index === 0 ? "dark" : "light")
                    color: theme.ink
                    font.pixelSize: 20
                }
                Repeater {
                    model: [100, 75, 50, 21, 1, 0]
                    delegate: Item {
                        id: column
                        required property int index
                        required property int modelData
                        x: 24 + index * 156
                        y: 55
                        width: 132
                        height: 230
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: column.modelData + "% / " + Math.round(column.modelData * 0.6) + "%"
                            color: theme.ink
                            font.pixelSize: 15
                        }
                        QuotaRings {
                            y: 30
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 76; height: 76
                            animationsEnabled: false
                            meters: [
                                { percent: column.modelData, color: "#42b4c5" },
                                { percent: column.modelData * 0.6, color: "#a181e8", warning: column.modelData < 25 }
                            ]
                        }
                        Row {
                            y: 125
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 12
                            Repeater {
                                model: [12, 22, 32]
                                delegate: QuotaRings {
                                    required property int modelData
                                    width: modelData; height: modelData
                                    animationsEnabled: false
                                    meters: [
                                        { percent: column.modelData, color: "#42b4c5" },
                                        { percent: column.modelData * 0.6, color: "#a181e8" }
                                    ]
                                }
                            }
                        }
                        Text {
                            y: 170
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "12 / 22 / 32 px"
                            color: theme.ink
                            font.pixelSize: 13
                        }
                        QuotaRings {
                            y: 200
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 24; height: 24
                            animationsEnabled: false
                            meters: [{ percent: column.modelData, color: "#5cbb80", warning: column.modelData < 25 }]
                        }
                    }
                }
            }
        }
    }

    Timer {
        interval: 500
        running: preview.outputPath.length > 0
        onTriggered: sheet.grabToImage(function(result) {
            if (!result.saveToFile(preview.outputPath)) {
                console.error("Could not save preview to", preview.outputPath)
                Qt.exit(1)
            } else {
                console.log("Saved preview to", preview.outputPath)
                Qt.quit()
            }
        })
    }
}
