import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Providers")
        icon: "view-list-details"
        source: "configProviders.qml"
    }
    ConfigCategory {
        name: i18n("Display")
        icon: "preferences-desktop-display"
        source: "configPanel.qml"
    }
    ConfigCategory {
        name: i18n("Notifications")
        icon: "preferences-desktop-notification"
        source: "configNotifications.qml"
    }
}
