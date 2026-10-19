import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kirigamiaddons.formcard as FormCard
import org.stoandl.gui

// Settings → About: which stoandl and which GUI run here, the licence, and one line with both versions to
// paste into a bug report. (Not Kirigami's AboutPage: it reads KAboutData, and this app links no KF6 C++.)
Kirigami.ScrollablePage {
    id: page
    objectName: "aboutSettings"
    title: "About"

    property string daemonVersion: ""

    readonly property string supportLine: "stoandl " + (page.daemonVersion || "not running")
                                          + " · stoandl-gui " + StoandlClient.guiVersion

    function reload() { page.daemonVersion = StoandlClient.daemonUp ? StoandlClient.daemonVersion() : ""; }

    function smokeExercise() { console.log("stoandl-smoke: about '" + page.supportLine + "'"); }

    Connections {
        target: StoandlClient
        function onDaemonUpChanged() { page.reload(); }
    }
    Component.onCompleted: page.reload()

    ColumnLayout {
        spacing: 0

        FormCard.FormHeader { title: "Versions" }
        FormCard.FormCard {
            FormCard.FormTextDelegate {
                text: "stoandl"
                description: page.daemonVersion !== "" ? page.daemonVersion : "Not running"
                icon.name: "chronometer-symbolic"
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormTextDelegate {
                text: "stoandl-gui"
                description: StoandlClient.guiVersion
                icon.name: "de.yoxcu.stoandl.gui"
            }
        }

        FormCard.FormHeader { title: "For a bug report" }
        FormCard.FormCard {
            FormCard.AbstractFormDelegate {
                background: null
                hoverEnabled: false
                contentItem: RowLayout {
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.TextField {
                        id: supportField
                        Layout.fillWidth: true
                        readOnly: true
                        text: page.supportLine
                    }
                    QQC2.Button {
                        text: "Copy"
                        icon.name: "edit-copy-symbolic"
                        onClicked: {
                            supportField.selectAll();
                            supportField.copy();
                            supportField.deselect();
                            applicationWindow().showPassiveNotification("Copied");
                        }
                    }
                }
            }
        }
        FormCard.FormSectionText {
            text: "A support bundle (Diagnostics & developer) has this and the logs, with secrets left out."
        }

        FormCard.FormHeader { title: "Licence" }
        FormCard.FormCard {
            FormCard.FormTextDelegate {
                text: "GNU General Public License, version 3"
                description: "stoandl and this app are free software: you may share and change them under its terms."
            }
            FormCard.FormDelegateSeparator {}
            FormCard.FormButtonDelegate {
                text: "Source code"
                description: "github.com/yoxcu/stoandl"
                icon.name: "internet-services-symbolic"
                onClicked: Qt.openUrlExternally("https://github.com/yoxcu/stoandl")
            }
        }
    }
}
