.pragma library

// Helpers for the schema-driven settings pages (SchemaSections, WatchSettingsPage). Their rows are
// created from a *shape* (which keys exist, of which type, in which section) and read everything else
// through per-row lookups, so a re-read rebuilds nothing as long as it hands QML back the very same
// objects for whatever did not change: a property re-evaluating to the same object notifies nobody, but
// an equal *new* object re-runs every binding that reads it (and resets a combo's model).

/** Deep equality for the plain data these pages hold (D-Bus records: strings, numbers, lists, maps). */
function same(a, b) {
    return JSON.stringify(a) === JSON.stringify(b);
}

/**
 * `next` (a key → object map) with every entry that equals its `prev` counterpart replaced by that
 * counterpart, so unchanged rows keep their identity. Returns `prev` itself when nothing changed at all,
 * so the caller can skip the assignment.
 */
function reuse(prev, next) {
    prev = prev || {};
    var out = {};
    var keys = Object.keys(next);
    var changed = keys.length !== Object.keys(prev).length;
    for (var i = 0; i < keys.length; ++i) {
        var k = keys[i];
        if (Object.prototype.hasOwnProperty.call(prev, k) && same(prev[k], next[k])) {
            out[k] = prev[k];
        } else {
            out[k] = next[k];
            changed = true;
        }
    }
    return changed ? out : prev;
}

/**
 * The row delegate under `item` whose modelData[field] is `key` (the smoke hooks press a row with it), or
 * null. Walks the item tree, so it is for tests, not for anything that runs per row.
 */
function findRow(item, field, key) {
    var kids = item ? item.children : [];
    for (var i = 0; i < kids.length; ++i) {
        var c = kids[i];
        if (c.modelData && c.modelData[field] === key)
            return c;
        var r = findRow(c, field, key);
        if (r)
            return r;
    }
    return null;
}

/** The RowHelp (?) button inside a row item, or null; for the smoke hooks, like findRow. */
function findHelp(item) {
    var kids = item ? item.children : [];
    for (var i = 0; i < kids.length; ++i) {
        var c = kids[i];
        if (c.holdPending !== undefined && c.toolTipText !== undefined)
            return c;
        var r = findHelp(c);
        if (r)
            return r;
    }
    return null;
}
