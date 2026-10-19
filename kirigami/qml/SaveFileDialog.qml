import QtQuick
import QtQuick.Dialogs as Dialogs

// A save dialog that proposes `fileName` in the folder it shows (openWithName()). The name is set when it
// opens: a bare name given to selectedFile up front resolves against this QML file's URL, and the dialog
// refuses it ("Cannot set … as a selected file because it doesn't exist").
Dialogs.FileDialog {
    id: dialog

    property string fileName: ""

    fileMode: Dialogs.FileDialog.SaveFile

    function openWithName() {
        dialog.selectedFile = dialog.currentFolder + "/" + dialog.fileName;
        dialog.open();
    }
}
