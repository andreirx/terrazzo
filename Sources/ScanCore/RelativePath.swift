//
//  RelativePath.swift — a node id expressed relative to some base directory.
//  Module maturity: PROTOTYPE (slice TZ-10)
//
//  TZ-10 items 4 + 1 (human field rulings 2026-08-17). Two places now show a node's path
//  RELATIVE to a base rather than as a bare filename or a full absolute path:
//    • the right-click ancestor-chain menu shows each level RELATIVE to the current
//      VIEWPORT folder (item 4 — "including the topmost visible ancestor");
//    • the Watchlist panel shows each entry's path RELATIVE to its VOLUME (item 1).
//  Both are the SAME pure string operation over the ratified id contract: a node id is an
//  absolute path and a descendant's id is `ancestor + "/" + name` (`FileSystemWalker.joinId`,
//  the same contract `WatchlistPath.isAncestor` relies on). It lives in ScanCore — which owns
//  that id contract — so `swift test` can pin it (the App layer is not an SPM target), exactly
//  like `WatchlistPath`.
//
//  ABSTRACTION LEDGER: a namespace of one pure static func (no type, no state). Concrete
//  users: `NavigationController` (menu rows relative to the focus; watchlist rows relative to
//  the volume) + `RelativePathTests`. Axis of variation: none — a fixed path-string relation.
//  Rejected simpler alternative: inline the prefix math at both App call sites — but the App is
//  SPM-invisible, so the rule could not be unit-tested, which the name-honesty/testability rules
//  require of a load-bearing string transform.
//

public enum RelativePath {
    /// `id` expressed relative to the directory `base`. Boundary-checked on the path separator
    /// (so `/Users` is never treated as a prefix of `/UsersFoo`):
    ///   - `id == base`                     → "." (the base itself);
    ///   - `id` strictly under `base`       → the remainder after `base/` (e.g. base "/Users",
    ///     id "/Users/apple/Library" → "apple/Library"); for the volume root base "/", the single
    ///     leading slash is dropped so "/Users/apple" → "Users/apple";
    ///   - `id` NOT under `base`            → `id` unchanged (an honest absolute fallback — never a
    ///     misleading relative path that pretends `id` lives under `base`).
    public static func of(_ id: String, under base: String) -> String {
        if id == base { return "." }
        // The prefix that marks "strictly inside base". For the volume root "/", that is just "/";
        // otherwise base + "/" (tolerating a base that already ends in "/", e.g. a re-rooted "/").
        let prefix = base == "/" ? "/" : (base.hasSuffix("/") ? base : base + "/")
        guard id.hasPrefix(prefix) else { return id }
        return String(id.dropFirst(prefix.count))
    }
}
