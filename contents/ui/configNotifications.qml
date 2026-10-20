import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import "components" as Components

KCM.SimpleKCM {
    id: page

    readonly property Controls.ScrollView scrollView: contentItem as Controls.ScrollView

    // Reserve the themed scrollbar width even when initial overflow disappears.
    Binding {
        target: page.scrollView
        property: page.mirrored ? "leftPadding" : "rightPadding"
        value: page.scrollView.Controls.ScrollBar.vertical.implicitWidth
    }

    property alias cfg_enableNotifications: enableNotificationsCheck.checked
    property bool cfg_enableNotificationsDefault: true
    property bool cfg_notifyStatusIncidents: false
    property bool cfg_notifyStatusIncidentsDefault: false
    property alias cfg_notifyQuotaWarnings: notifyQuotaWarningsCheck.checked
    property bool cfg_notifyQuotaWarningsDefault: true
    property alias cfg_notifyPredictivePaceWarnings: notifyPredictivePaceWarningsCheck.checked
    property bool cfg_notifyPredictivePaceWarningsDefault: false
    property alias cfg_notifyLimitResets: notifyLimitResetsCheck.checked
    property bool cfg_notifyLimitResetsDefault: false
    property alias cfg_quotaWarningPercent: quotaWarningPercentSpin.value
    property int cfg_quotaWarningPercentDefault: 80
    property alias cfg_quotaCriticalPercent: quotaCriticalPercentSpin.value
    property int cfg_quotaCriticalPercentDefault: 95
    property alias cfg_showQuotaWarningMarkers: showQuotaWarningMarkersCheck.checked
    property bool cfg_showQuotaWarningMarkersDefault: true
    Kirigami.FormLayout {
        Kirigami.Separator {
            Kirigami.FormData.label: i18n("Thresholds")
            Kirigami.FormData.isSection: true
        }

        Controls.SpinBox {
            id: quotaWarningPercentSpin
            objectName: "quotaWarningPercentSpin"
            Kirigami.FormData.label: i18n("Warn at (% used):")
            from: 1
            to: 99
            editable: true
            // Unparsable text keeps the current threshold. Substituting the
            // schema default here would move a configured threshold silently.
            valueFromText: function(text, locale) {
                var match = text.match(/\d+/)
                return match ? parseInt(match[0], 10) : value
            }
            Layout.preferredWidth: Kirigami.Units.gridUnit * 10
        }

        Controls.SpinBox {
            id: quotaCriticalPercentSpin
            objectName: "quotaCriticalPercentSpin"
            Kirigami.FormData.label: i18n("Critical at (% used):")
            // Keeping the floor on the warning value makes the "critical is never
            // below warning" rule visible here instead of only correcting it at
            // runtime, where the widget would silently ignore the entered number.
            from: quotaWarningPercentSpin.value
            to: 100
            editable: true
            valueFromText: function(text, locale) {
                var match = text.match(/\d+/)
                return match ? parseInt(match[0], 10) : value
            }
            Layout.preferredWidth: Kirigami.Units.gridUnit * 10
        }

        Controls.CheckBox {
            id: showQuotaWarningMarkersCheck
            objectName: "showQuotaWarningMarkersCheck"
            Layout.fillWidth: true
            text: i18n("Color meters at warning thresholds")
        }

        Kirigami.Separator {
            Kirigami.FormData.label: i18n("Notifications")
            Kirigami.FormData.isSection: true
        }

        Controls.CheckBox {
            id: enableNotificationsCheck
            Layout.fillWidth: true
            text: i18n("Send notifications")
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Controls.CheckBox {
                id: notifyQuotaWarningsCheck
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit
                text: i18n("Quota reaches a threshold")
                enabled: enableNotificationsCheck.checked
            }

            Controls.CheckBox {
                id: notifyPredictivePaceWarningsCheck
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit
                text: i18n("Quota will run out before it resets")
                enabled: enableNotificationsCheck.checked

                Components.PlainToolTip {
                    parent: notifyPredictivePaceWarningsCheck
                    plainText: i18n("Based on the CLI's pace forecast.")
                    visible: notifyPredictivePaceWarningsCheck.hovered || notifyPredictivePaceWarningsCheck.visualFocus
                    delay: Kirigami.Units.toolTipDelay
                }
            }

            Controls.CheckBox {
                id: notifyLimitResetsCheck
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit
                text: i18n("Quota resets")
                enabled: enableNotificationsCheck.checked
            }

        }
    }
}
