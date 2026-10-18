.pragma library

// Helpers for the schema-driven settings pages (GeneralSettingsPage, WatchSettingsPage). Their rows are
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
