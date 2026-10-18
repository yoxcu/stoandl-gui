.pragma library

// The daemon's list encoding (ConfList.kt): items joined by ',', "\," for a comma and "\\" for a
// backslash inside an item, any other backslash literal; items trimmed, blank ones dropped.

function decode(raw) {
    var items = [];
    var cur = "";
    var s = raw || "";
    for (var i = 0; i < s.length; ++i) {
        var c = s[i];
        var next = s[i + 1];
        if (c === "\\" && (next === "," || next === "\\")) { cur += next; ++i; }
        else if (c === ",") { items.push(cur); cur = ""; }
        else cur += c;
    }
    items.push(cur);
    return items.map(function (x) { return x.trim(); }).filter(function (x) { return x !== ""; });
}

function encode(items) {
    return (items || []).map(function (x) { return String(x).trim(); })
        .filter(function (x) { return x !== ""; })
        .map(function (x) { return x.replace(/\\/g, "\\\\").replace(/,/g, "\\,"); })
        .join(",");
}
