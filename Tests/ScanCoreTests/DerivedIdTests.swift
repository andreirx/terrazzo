//
//  DerivedIdTests.swift — TZ-9 Phase B: ids derived from the parent chain, no retained path.
//  Module maturity: PROTOTYPE (slice TZ-9b)
//
//  Phase B removed the last retained id copy (`Node.id`): a node's id derives on demand from
//  `parent` links + `name`s (the walker's `joinId` contract), and the `retainedIds` side map
//  holds a string ONLY where derivation is impossible — (a) transiently, for a node created by
//  an event that arrived before its discovery stub, and (b) permanently, for CONTRACT-VIOLATING
//  (synthetic/opaque) ids, which must still round-trip verbatim (the verify harness replays the
//  fixture tree, ids like "n028:System", through this reducer — the settled synthetic-id gate).
//
//  These tests pin the two claims the 214-test behavior ratchet cannot see:
//    1. THE DRAIN — after a contract-following fold, ZERO id strings are retained
//       (`retainedIdCount`, the internal read-only seam) — the memory claim itself, including
//       across the size-before-stub ordering that forces transient retention.
//    2. VERBATIM SYNTHETIC IDS — a fixture-shaped tree (display-name root, "n028:System"-style
//       ids, names containing "/") folds and projects byte-identical ids, and lookups stay exact.
//

import XCTest
@testable import ScanCore

final class DerivedIdTests: XCTestCase {

    // MARK: - 1. The drain (contract-following ids retain no string)

    /// Size/denied events arriving BEFORE the discovery stub force transient retention (the node
    /// is unlinked, so its id cannot be derived); the stub must RESOLVE it — after the full fold
    /// the store retains ZERO id strings, and every id still resolves and projects correctly.
    func testContractIdsDrainToZeroAcrossSizeBeforeStub() {
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([
            // Deep descendant sized BEFORE anything links it (grandparent not yet known either).
            .sizeUpdated(nodeId: "/r/a/b", allocated: 7, logical: 7),
            .accessDenied(nodeId: "/r/locked"),
            .sizeUpdated(nodeId: "/r", allocated: 1, logical: 1),
        ])
        XCTAssertTrue(r.contains("/r/a/b"), "pre-stub node must be findable via its retained id")
        XCTAssertGreaterThan(r.retainedIdCount, 0, "unlinked nodes must retain their ids (else they are unfindable)")

        r.apply([
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: "/r/a", name: "a", kind: .dir),
                ChildStub(id: "/r/locked", name: "locked", kind: .dir),
            ]),
            .childrenDiscovered(parentId: "/r/a", children: [
                ChildStub(id: "/r/a/b", name: "b", kind: .file),
            ]),
            .sizeUpdated(nodeId: "/r/a", allocated: 2, logical: 2),
            .subtreeCompleted(nodeId: "/r"),
        ])

        XCTAssertEqual(r.retainedIdCount, 0,
                       "THE MEMORY LAW: after a contract-following fold, no id strings may remain retained")
        // Ids still resolve exactly and project verbatim.
        XCTAssertEqual(r.ownSize(of: "/r/a/b")?.allocated, 7)
        let tree = r.makeTree()
        XCTAssertEqual(tree.id, "/r")
        let a = tree.children.first { $0.id == "/r/a" }
        XCTAssertEqual(a?.children.map(\.id), ["/r/a/b"])
        XCTAssertEqual(tree.children.map(\.id).sorted(), ["/r/a", "/r/locked"])
        XCTAssertEqual(tree.allocatedBytes, 10) // 1 + 2 + 7 (locked denied: no size)
    }

    /// The volume root: rootId "/" must not derive "//name" ids (`joinId`'s one special case).
    func testVolumeRootDerivation() {
        var r = ScanReducer(rootId: "/", rootName: "Macintosh HD") // display name ≠ path component
        r.apply([
            .childrenDiscovered(parentId: "/", children: [
                ChildStub(id: "/Users", name: "Users", kind: .dir)]),
            .childrenDiscovered(parentId: "/Users", children: [
                ChildStub(id: "/Users/apple", name: "apple", kind: .dir)]),
            .sizeUpdated(nodeId: "/Users/apple", allocated: 5, logical: 5),
        ])
        XCTAssertEqual(r.retainedIdCount, 0)
        XCTAssertTrue(r.contains("/Users/apple"))
        let tree = r.makeTree()
        XCTAssertEqual(tree.children.map(\.id), ["/Users"])
        XCTAssertEqual(tree.children.first?.children.map(\.id), ["/Users/apple"])
    }

    /// Root promotion keeps the drain: after `reRoot` the old root's id becomes derivable through
    /// the new root (production names are path components), so nothing is retained.
    func testReRootKeepsIdsDerivable() {
        var r = ScanReducer(rootId: "/Users/apple", rootName: "apple")
        r.apply([
            .sizeUpdated(nodeId: "/Users/apple", allocated: 3, logical: 3),
            .childrenDiscovered(parentId: "/Users/apple", children: [
                ChildStub(id: "/Users/apple/doc", name: "doc", kind: .file)]),
            .sizeUpdated(nodeId: "/Users/apple/doc", allocated: 4, logical: 4),
        ])
        r.reRoot(to: "/Users", newRootName: "Users")
        XCTAssertEqual(r.retainedIdCount, 0,
                       "a contract-following promotion must leave every id derivable")
        XCTAssertTrue(r.contains("/Users/apple/doc"))
        let tree = r.makeTree()
        XCTAssertEqual(tree.id, "/Users")
        XCTAssertEqual(tree.children.map(\.id), ["/Users/apple"])
        XCTAssertEqual(tree.children.first?.children.map(\.id), ["/Users/apple/doc"])
        XCTAssertEqual(tree.allocatedBytes, 7)
    }

    // MARK: - 2. Synthetic (contract-violating) ids round-trip verbatim

    /// The verify harness's fixture shape: a display-name root id ("root:Macintosh HD"), child ids
    /// that are NOT parent+"/"+name ("n028:System"), and a NAME containing "/" ("System/1" — real
    /// fixture content). All must fold, look up exactly, and project BYTE-IDENTICAL ids — the
    /// frozen opaque-id API (and the fixture goldens) depend on it.
    func testSyntheticIdsRoundTripVerbatim() {
        var r = ScanReducer(rootId: "root:Macintosh HD", rootName: "Macintosh HD")
        r.apply([
            .sizeUpdated(nodeId: "root:Macintosh HD", allocated: 1, logical: 1),
            .childrenDiscovered(parentId: "root:Macintosh HD", children: [
                ChildStub(id: "n028:System", name: "System", kind: .dir),
            ]),
            .childrenDiscovered(parentId: "n028:System", children: [
                ChildStub(id: "n014:System/1", name: "System/1", kind: .dir),
                ChildStub(id: "n001:System-f0", name: "System-f0", kind: .file),
            ]),
            .sizeUpdated(nodeId: "n028:System", allocated: 2, logical: 2),
            .sizeUpdated(nodeId: "n014:System/1", allocated: 4, logical: 4),
            .sizeUpdated(nodeId: "n001:System-f0", allocated: 8, logical: 8),
            .subtreeCompleted(nodeId: "root:Macintosh HD"),
        ])

        // Contract-violating ids are retained (they cannot derive) — and ONLY those (root never).
        XCTAssertEqual(r.retainedIdCount, 3, "one retained id per contract-violating non-root node")

        // Exact lookups: near-miss ids (what derivation WOULD produce) must not resolve.
        XCTAssertTrue(r.contains("n028:System"))
        XCTAssertFalse(r.contains("root:Macintosh HD/System"),
                       "a derived-shape alias of a synthetic id must not resolve")
        XCTAssertEqual(r.ownSize(of: "n014:System/1")?.allocated, 4)

        // Projection echoes the synthetic ids byte-identically (fixture-golden requirement).
        let tree = r.makeTree()
        XCTAssertEqual(tree.id, "root:Macintosh HD")
        XCTAssertEqual(tree.children.map(\.id), ["n028:System"])
        let system = tree.children[0]
        XCTAssertEqual(system.children.map(\.id).sorted(), ["n001:System-f0", "n014:System/1"])
        XCTAssertEqual(tree.allocatedBytes, 15)

        // Prune a synthetic-id subtree: the id (and its retained string) must be genuinely gone.
        r.apply(.childRemoved(parentId: "n028:System", childId: "n014:System/1"))
        XCTAssertFalse(r.contains("n014:System/1"))
        XCTAssertEqual(r.retainedIdCount, 2, "the pruned node's retained id must be released")
        XCTAssertEqual(r.makeTree().allocatedBytes, 11)
    }

    // MARK: - 3. ONE byte-exact id relation (review-1 change 1 — canonical-equivalence regressions)
    //
    // Swift's `String ==` is CANONICAL equivalence: a decomposed and a precomposed spelling of
    // "José" compare equal even though their UTF-8 bytes differ. The store's id identity is BYTE
    // equality (`PathKey` hashes bytes; `slotMatches` compares bytes), so every derivability /
    // verification decision must use the same byte relation (`sameIdBytes`). These tests pin the
    // review-1 defect: a canonical `==` at any of those sites lets a byte-distinct spelling drop
    // the retained verbatim id (unfindable thereafter, projection emits different bytes) or merge
    // two distinct byte ids into one node. Note: `XCTAssertEqual` on `String` is canonical too —
    // byte-verbatim claims below are asserted via `utf8.elementsEqual`, never string `==`.

    /// "José" decomposed (e + U+0301 combining acute) vs precomposed (U+00E9). Canonically equal,
    /// byte-distinct — the seam every canonical-`==` bug hides behind.
    private static let nfdName = "Jose\u{0301}"
    private static let nfcName = "Jos\u{00E9}"

    /// The premise itself, pinned: if these two ever stop being canonically-equal-but-byte-distinct
    /// the whole section is vacuous — fail loudly instead.
    func testSpellingPremise() {
        XCTAssertEqual(Self.nfdName, Self.nfcName, "must be CANONICALLY equal (Swift ==)")
        XCTAssertFalse(Self.nfdName.utf8.elementsEqual(Self.nfcName.utf8), "must be BYTE-distinct")
    }

    /// CHILD LINKING: a stub whose id tail is byte-distinct from its name (NFD id, NFC name) is
    /// NOT derivable — the verbatim id must stay retained, exact byte lookup must keep working,
    /// the derived-shape alias must NOT resolve, and projection must echo the id byte-verbatim.
    /// (Canonical `==` called this derivable, dropped the string, and broke all three.)
    func testChildLinkingKeepsByteDistinctCanonicallyEquivalentId() {
        let nfdId = "/r/" + Self.nfdName          // the id's bytes (decomposed)
        let derivedAlias = "/r/" + Self.nfcName   // what derivation from the NFC name yields
        var r = ScanReducer(rootId: "/r", rootName: "r")
        r.apply([
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: nfdId, name: Self.nfcName, kind: .file), // name bytes ≠ id tail bytes
            ]),
            .sizeUpdated(nodeId: nfdId, allocated: 9, logical: 9),
        ])
        XCTAssertEqual(r.retainedIdCount, 1,
                       "a byte-distinct id must stay retained — canonical == must not call it derivable")
        XCTAssertTrue(r.contains(nfdId), "exact byte lookup of the verbatim id must resolve")
        XCTAssertFalse(r.contains(derivedAlias),
                       "the derived-shape NFC alias is a DIFFERENT byte id and must not resolve")
        XCTAssertEqual(r.ownSize(of: nfdId)?.allocated, 9)
        let child = r.makeTree().children.first
        XCTAssertNotNil(child)
        XCTAssertTrue(child!.id.utf8.elementsEqual(nfdId.utf8), "projected id must be BYTE-verbatim")
    }

    /// ROOT PROMOTION: an old root whose id is byte-distinct from `joinId(newRootId, name)` (NFD
    /// id, NFC display name) must keep its verbatim id retained across `reRoot` — same defect
    /// shape as child linking, at the graft site.
    func testReRootKeepsByteDistinctOldRootIdVerbatim() {
        let nfdOldRoot = "/Users/" + Self.nfdName
        var r = ScanReducer(rootId: nfdOldRoot, rootName: Self.nfcName) // NFC display name
        r.apply(.sizeUpdated(nodeId: nfdOldRoot, allocated: 3, logical: 3))
        r.reRoot(to: "/Users", newRootName: "Users")
        XCTAssertEqual(r.retainedIdCount, 1,
                       "the grafted old root's byte-distinct id must stay retained")
        XCTAssertTrue(r.contains(nfdOldRoot))
        XCTAssertFalse(r.contains("/Users/" + Self.nfcName),
                       "the derived-shape NFC alias must not resolve")
        let tree = r.makeTree()
        XCTAssertEqual(tree.id, "/Users")
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertTrue(tree.children[0].id.utf8.elementsEqual(nfdOldRoot.utf8),
                      "grafted root id must project BYTE-verbatim")
        XCTAssertEqual(tree.allocatedBytes, 3)
    }

    /// The `reRoot` ALREADY-THERE guard is byte-exact too: promoting to a canonically-equal but
    /// byte-DISTINCT id is a REAL promotion (a distinct node becomes the root), never a silent
    /// no-op that leaves `rootId` pointing at different bytes than the caller requested.
    func testReRootToByteDistinctCanonicallyEquivalentIdIsARealPromotion() {
        let nfcRoot = "/Volumes/" + Self.nfcName
        let nfdRoot = "/Volumes/" + Self.nfdName
        var r = ScanReducer(rootId: nfcRoot, rootName: Self.nfcName)
        r.apply(.sizeUpdated(nodeId: nfcRoot, allocated: 5, logical: 5))
        r.reRoot(to: nfdRoot, newRootName: Self.nfdName)
        let tree = r.makeTree()
        XCTAssertTrue(tree.id.utf8.elementsEqual(nfdRoot.utf8),
                      "the requested byte-distinct id must actually become the root")
        XCTAssertEqual(tree.children.count, 1, "the old root is grafted as a child — a real promotion")
        XCTAssertTrue(tree.children[0].id.utf8.elementsEqual(nfcRoot.utf8),
                      "the old root's id must survive BYTE-verbatim")
        XCTAssertTrue(r.contains(nfcRoot))
        XCTAssertTrue(r.contains(nfdRoot))
        XCTAssertEqual(tree.allocatedBytes, 5)
    }

    /// FORCED HASH COLLISION (the byte-exact collision-identity contract, review-1): both
    /// spellings forced onto ONE 128-bit key, BOTH contract-following (each name's bytes match its
    /// id's tail) — so NO retained strings exist and the parent-chain byte compare ALONE must keep
    /// the two byte-distinct, canonically-equal ids apart. (The pre-fix retained-arm canonical `==`
    /// merged them at `ensureSlot` time.)
    func testForcedCollisionKeepsCanonicallyEquivalentIdsDistinct() {
        let nfdId = "/r/" + Self.nfdName
        let nfcId = "/r/" + Self.nfcName
        // Canonical `==` in the TEST HASHER is deliberate: it maps BOTH spellings to key (7,7).
        var r = ScanReducer(rootId: "/r", rootName: "r", rawHashForTesting: { id in
            if id == nfdId { return (7, 7) }
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
            return (h, h &* 0x9e37_79b9_7f4a_7c15)
        })
        r.apply([
            .childrenDiscovered(parentId: "/r", children: [
                ChildStub(id: nfdId, name: Self.nfdName, kind: .file), // derivable (byte-exact)
                ChildStub(id: nfcId, name: Self.nfcName, kind: .file), // derivable (byte-exact)
            ]),
            .sizeUpdated(nodeId: nfdId, allocated: 10, logical: 10),
            .sizeUpdated(nodeId: nfcId, allocated: 20, logical: 20),
        ])
        XCTAssertEqual(r.retainedIdCount, 0,
                       "both spellings are contract-following — the chain walk alone must distinguish them")
        XCTAssertEqual(r.ownSize(of: nfdId)?.allocated, 10)
        XCTAssertEqual(r.ownSize(of: nfcId)?.allocated, 20)
        XCTAssertEqual(r.processedCount, 2, "a canonical merge would have collapsed this to 1")
        let ids = r.makeTree().children.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains { $0.utf8.elementsEqual(nfdId.utf8) })
        XCTAssertTrue(ids.contains { $0.utf8.elementsEqual(nfcId.utf8) })
    }

    /// FORCED COLLISION at the ROOT arm: a canonically-equal byte-distinct probe sharing the
    /// root's key must NOT resolve to the root (the pre-fix `id == rootId` accepted it).
    func testForcedCollisionRootArmIsByteExact() {
        let nfcRoot = "/" + Self.nfcName
        let nfdProbe = "/" + Self.nfdName
        var r = ScanReducer(rootId: nfcRoot, rootName: Self.nfcName, rawHashForTesting: { id in
            if id == nfcRoot { return (9, 9) } // canonical == — catches BOTH spellings → one key
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
            return (h, h &* 0x9e37_79b9_7f4a_7c15)
        })
        r.apply(.sizeUpdated(nodeId: nfcRoot, allocated: 5, logical: 5))
        XCTAssertTrue(r.contains(nfcRoot))
        XCTAssertFalse(r.contains(nfdProbe),
                       "the root arm must be byte-exact: a canonically-equal spelling is a different id")
    }
}
