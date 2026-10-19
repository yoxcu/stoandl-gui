import QtQml
import org.stoandl.gui

// One stoandl.conf switch an empty state offers to turn on ("No plugins" → plugins.enabled): its label and
// what it makes stoandl contact come from the daemon's (cached) schema, its value from GetConfig, so the
// offer names exactly the key and the hosts the Settings row does. Follows ConfigChanged for the key.
QtObject {
    id: k

    /** The schema key, e.g. "plugins.enabled". */
    property string key: ""
    /** Its schema label ("Plugins"), and the egress column (a noun phrase after "Contacts"; "" = none). */
    property string label: ""
    property string egress: ""
    /** The value is known (read from a daemon that has the key) and on. */
    property bool known: false
    property bool isOn: false

    /** "Contacts …." or that nothing leaves this device, for the offer's description. */
    readonly property string egressText: k.egress !== "" ? "Contacts " + k.egress + "." : "Nothing leaves this device."

    function reload() {
        if (!StoandlClient.daemonUp) {
            k.known = false;
            return;
        }
        StoandlClient.fetch(k, [["configSchema"], ["getConfig"]], function (r) {
            var row = (r[0] || []).find(function (f) { return f.key === k.key; });
            var value = ((r[1] && r[1].values) || {})[k.key];
            k.label = row ? row.label : k.key;
            k.egress = row ? row.egress : "";
            k.known = row !== undefined && value !== undefined;
            k.isOn = value === "true";
        });
    }

    function turnOn() {
        var r = StoandlClient.setConfig(k.key, "true");
        StoandlClient.fetch(k, ["getConfig"], function (c) { k.isOn = ((c && c.values) || {})[k.key] === "true"; });
        applicationWindow().showPassiveNotification(r.ok ? k.label + " is on" : "Could not turn " + k.label + " on: " + (r.tail || r.kind));
        return r;
    }

    Component.onCompleted: k.reload()

    property Connections _follow: Connections {
        target: StoandlClient
        function onDaemonUpChanged() { k.reload(); }
        function onConfigChanged(changed) { if (changed === k.key) k.reload(); }
    }
}
