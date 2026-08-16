//
//  DirectoryReader.swift — the getattrlistbulk directory-enumeration primitive.
//  Module maturity: PROTOTYPE (slice TZ-6 — the 120× hot-loop fix)
//
//  WHY THIS EXISTS (TZ-6, measured). The walker's old per-entry path went through
//  Foundation: `FileManager.contentsOfDirectory` (an NSArray of firmlink-canonicalized
//  NSURLs) + two `URLResourceValues` fetches per entry + `measure`'s
//  `totalFileAllocatedSize` resource fetch — an ObjC round-trip AND several
//  stat-family syscalls PER ENTRY. The getattrlistbulk path below returns a WHOLE
//  DIRECTORY of attributes per syscall (the Finder path, PLAN §TZ-6) and carries each
//  regular file's allocated + data length inline, so a file needs ZERO additional
//  syscalls. The per-phase attribution (enumeration / attributes / id+event build /
//  actor sends) is MEASURED, not inferred — run `scripts/profile.sh` and read the
//  TZPROFILE line; the profiling hook is `ReaderProfile` (below), nil in production.
//
//  NO FOUNDATION URL IN THE PER-ENTRY PATH (packet deliverable 2). This reads raw C
//  structs (getattrlistbulk buffers, lstat) and hands out plain Swift value records at
//  the directory boundary. It is the single enumeration primitive; every syscall stays
//  in ScanFS (CLAUDE.md constraint 1).
//
//  SIZE FIDELITY (the golden constraint). The FixtureFS golden recomputes every node's
//  size with `FileSystemWalker.measure` (Foundation `totalFileAllocatedSize`), so the
//  rewrite MUST reproduce those numbers. Verified on this APFS host over ~60k real
//  nodes (files, dirs, symlinks, compressed system files) with ZERO divergence:
//    - a regular file's ATTR_FILE_ALLOCSIZE  == its totalFileAllocatedSize, and
//      ATTR_FILE_DATALENGTH == st_size (logical);
//    - a directory's / symlink's st_blocks*512 == its totalFileAllocatedSize
//      (`measure` already uses st_blocks for symlinks).
//  So: regular files take size from the bulk buffer (free); dirs and symlinks take one
//  `lstat` (st_blocks*512, st_size) — the same value `measure` would return. The golden
//  gate is the deterministic proof this holds on the fixture tree.
//
//  TRUNCATION IS NOT ENUMERATION (TZ-6 revise finding 1 — "the one sin this product
//  exists to end"). A `getattrlistbulk` call can fail mid-directory (it returns -1 with
//  a set errno after having handed back earlier entries). Returning the entries read so
//  far AS IF COMPLETE would silently drop the unread remainder — a silent omission, the
//  exact failure VISION forbids. So `read` returns a THREE-WAY `ReadResult`:
//    - `.complete` — the directory was enumerated to exhaustion (count reached 0);
//    - `.partial`  — a transient EINTR was retried, but a later call failed for another
//                    reason after some entries were read: the caller SHOWS what was read
//                    AND marks the directory `accessDenied` (a "we don't know the rest"
//                    tile), never a wrong-but-quiet total;
//    - `.unreadable` — the directory could not be opened or the very first bulk call
//                    failed: the caller emits `accessDenied` with no children.
//  EINTR (a signal interrupted the syscall) is RETRIED in place — it is not a truncation,
//  just an interruption — which is the "retry then deny" the revise note names.
//
//  Module maturity: PROTOTYPE — the attribute set, Child shape, and ReadResult are TZ-6
//  contracts.
//

import Foundation
import Darwin

/// Enumerate one directory's immediate children with type + size + (for dirs) device,
/// in bulk, as raw value records. NOT recursive; NOT policy-aware — `FileSystemWalker`
/// applies bundle-leaf / symlink / device policy over these records.
enum DirectoryReader {

    /// What a child intrinsically is, as far as descent cares. Anything that is neither
    /// a directory nor a symlink (regular files AND the rare device/socket/fifo nodes)
    /// is a `.file` leaf — matching the walker's old `else` branch.
    enum Kind: Equatable { case dir, file, symlink }

    /// One directory entry as a plain value crossing out of the syscall layer.
    struct Child {
        let name: String
        let kind: Kind
        /// The child's `st_dev` — meaningful ONLY for `.dir` (the one-scan-one-device
        /// invariant checks child directories). 0 for files/symlinks (never entered, so
        /// their device is irrelevant). Read from the same `lstat` that sizes a dir.
        let device: dev_t
        /// On-disk allocated bytes == `measure().allocated` for this entry (see header).
        let allocated: Int64
        /// Apparent bytes (`st_size`) == `measure().logical`.
        let logical: Int64
    }

    /// The outcome of enumerating one directory — a SUM TYPE because the three cases are
    /// mutually exclusive and demand different honest renderings (see header "TRUNCATION
    /// IS NOT ENUMERATION"). An exhaustive `switch` at every call site is the deterministic
    /// list of places that must decide what to do about a truncated read; a
    /// `([Child], Bool)` tuple would let a caller read the children and forget the flag —
    /// the exact silent-omission shape this type forbids.
    enum ReadResult {
        /// Enumerated to exhaustion — every child is present.
        case complete([Child])
        /// A mid-stream failure truncated the enumeration after these children were read.
        /// The remainder is UNKNOWN — the caller shows these AND denies the directory.
        case partial([Child])
        /// Could not open the directory, or the first bulk call failed — nothing was read.
        case unreadable
    }

    #if DEBUG
    /// TEST-ONLY fault-injection seam (review-0 change 4). A `.partial` `ReadResult` can only
    /// arise from a mid-directory `getattrlistbulk` failure — impossible to force from
    /// userspace without a fault-injecting filesystem. When set, `read` returns the injected
    /// result for a chosen `dirPath` (and reads normally for every other path), so the REAL
    /// `classifyChildren` → walk → emit path runs end-to-end on a partial read and the
    /// no-silent-truncation `accessDenied` emission is proven by observing events — not by
    /// asserting a flag against itself (the tautology the finding rejected).
    ///
    /// Compiled OUT of release builds: `scripts/build.sh` / `verify.sh` / `profile.sh` /
    /// `scanrate.sh` all invoke `swiftc -O` with NO `-DDEBUG`, so the app and every host
    /// tool ship without this symbol and without the per-read check; only `swift test`
    /// (debug config, `DEBUG` defined) compiles it in. `nonisolated(unsafe)` because a test
    /// sets it synchronously in setup before any concurrent read; production never touches it.
    ///
    /// Abstraction ledger — faultInjector: concrete user = `DirectoryReaderTests`
    /// (`testPartialReadIsDeniedNotSwallowed`); axis = injecting the un-forceable `.partial`
    /// outcome into the real read; rejected alternative = asserting `Classified.incomplete`
    /// in isolation (the prior flag-only tautology the reviewer struck).
    nonisolated(unsafe) static var faultInjector: (@Sendable (String) -> ReadResult?)?
    #endif

    /// Single-threaded profiling accumulator (packet deliverable / revise finding 5).
    /// nil in production (the walker passes nothing) — a nil-guarded hook so the REAL
    /// hot loop is what gets measured by `scripts/profile.sh`, not a reimplementation
    /// that would drift from it. Concrete user: `scan_profile_host`. Axis: per-phase
    /// time attribution of the production reader. Rejected alternative: a standalone
    /// reimplementation of the getattrlistbulk parse in the profiler — non-trivial
    /// unsafe-pointer duplication that would measure a DIFFERENT code path than ships.
    final class ReaderProfile {
        var bulkNanos: UInt64 = 0   // time in getattrlistbulk syscalls — the ENUMERATION phase
        var attrNanos: UInt64 = 0   // time in per-entry lstat        — the ATTRIBUTES phase
        var bulkCalls: Int = 0
        var lstatCalls: Int = 0
        init() {}
    }

    /// fsobj_type_t (vnode type) values from <sys/vnode.h>, stable ABI. Only DIR and LNK
    /// are distinguished; everything else is a leaf. Hardcoded (the enum imports as bare
    /// Int32s that read less clearly than these named constants at the one use site).
    private static let VDIR: UInt32 = 2
    private static let VLNK: UInt32 = 5

    /// `lstat` with optional timing (see `ReaderProfile`). Zero overhead when `profile`
    /// is nil (one optional test); attributed to the ATTRIBUTES phase when profiling.
    private static func timedLstat(_ path: String, _ st: inout stat, _ profile: ReaderProfile?) -> Int32 {
        guard let profile else { return lstat(path, &st) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = lstat(path, &st)
        profile.attrNanos &+= DispatchTime.now().uptimeNanoseconds &- t0
        profile.lstatCalls += 1
        return r
    }

    /// Read `dirPath`'s immediate children. See `ReadResult` for the three honest outcomes
    /// (complete / partial / unreadable) — a truncated enumeration is NEVER reported as
    /// complete (VISION §"invisible space is first-class"). Hidden entries are ALWAYS
    /// included (getattrlistbulk returns dotfiles; it omits "." / ".."). Symlinks are
    /// reported as `.symlink` and NEVER opened.
    static func read(_ dirPath: String, profile: ReaderProfile? = nil) -> ReadResult {
        #if DEBUG
        // TEST-ONLY (see `faultInjector`): substitute the outcome for a chosen directory so the
        // real classify→walk→emit path runs on a `.partial`. Absent in release builds.
        if let inject = faultInjector, let injected = inject(dirPath) { return injected }
        #endif
        let fd = open(dirPath, O_RDONLY, 0)
        if fd < 0 { return .unreadable }
        defer { close(fd) }

        // Attribute set (bit order within a group; RETURNED_ATTRS is always returned
        // first regardless of its bit): common {RETURNED, NAME, OBJTYPE}, file
        // {ALLOCSIZE, DATALENGTH}. Directories/symlinks carry no file attrs — the
        // per-entry RETURNED_ATTRS mask tells us which fields are actually present.
        func ag<T: BinaryInteger>(_ x: T) -> UInt32 { UInt32(truncatingIfNeeded: x) }
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = ag(ATTR_CMN_RETURNED_ATTRS) | ag(ATTR_CMN_NAME) | ag(ATTR_CMN_OBJTYPE)
        al.fileattr = ag(ATTR_FILE_ALLOCSIZE) | ag(ATTR_FILE_DATALENGTH)

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var out: [Child] = []
        while true {
            let count: Int32
            if let profile {
                let t0 = DispatchTime.now().uptimeNanoseconds
                count = getattrlistbulk(fd, &al, buf, bufSize, 0)
                profile.bulkNanos &+= DispatchTime.now().uptimeNanoseconds &- t0
                profile.bulkCalls += 1
            } else {
                count = getattrlistbulk(fd, &al, buf, bufSize, 0)
            }
            if count < 0 {
                // A signal interrupted the syscall — not a truncation, just retry in place.
                if errno == EINTR { continue }
                // A real mid-stream failure: what we read is HONEST but INCOMPLETE. Never
                // present it as complete — surface the partial-ness so the caller denies the
                // unread remainder (revise finding 1). An error on the very first call
                // (nothing read) is a plain unreadable directory.
                return out.isEmpty ? .unreadable : .partial(out)
            }
            if count == 0 { break }   // exhausted — a genuine complete enumeration
            var entry = buf
            for _ in 0..<count {
                let entryLen = Int(entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                var off = MemoryLayout<UInt32>.size

                // ATTR_CMN_RETURNED_ATTRS (always first) — the presence mask for this entry.
                let returned = entry.loadUnaligned(fromByteOffset: off, as: attribute_set_t.self)
                off += MemoryLayout<attribute_set_t>.size

                var name = ""
                var objtype: UInt32 = 0
                var allocSize: Int64 = 0
                var dataLength: Int64 = 0
                var hasFileSize = false

                if (returned.commonattr & ag(ATTR_CMN_NAME)) != 0 {
                    // attrreference_t: {int32 attr_dataoffset (relative to the reference),
                    // uint32 attr_length}. The name bytes sit at (reference + dataoffset).
                    let dataOffset = entry.loadUnaligned(fromByteOffset: off, as: Int32.self)
                    let namePtr = entry.advanced(by: off + Int(dataOffset))
                    name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
                    off += MemoryLayout<attrreference_t>.size
                }
                if (returned.commonattr & ag(ATTR_CMN_OBJTYPE)) != 0 {
                    objtype = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                    off += MemoryLayout<fsobj_type_t>.size
                }
                if (returned.fileattr & ag(ATTR_FILE_ALLOCSIZE)) != 0 {
                    allocSize = entry.loadUnaligned(fromByteOffset: off, as: Int64.self)
                    off += MemoryLayout<off_t>.size
                    hasFileSize = true
                }
                if (returned.fileattr & ag(ATTR_FILE_DATALENGTH)) != 0 {
                    dataLength = entry.loadUnaligned(fromByteOffset: off, as: Int64.self)
                    off += MemoryLayout<off_t>.size
                }

                if !name.isEmpty && name != "." && name != ".." {
                    let child: Child
                    switch objtype {
                    case VDIR:
                        // A directory carries no file attrs — one lstat gives its own-entry
                        // size AND its device (the one-scan-one-device check). st_blocks*512
                        // == totalFileAllocatedSize for a dir (verified — see header).
                        var st = stat()
                        if timedLstat(dirPath + "/" + name, &st, profile) == 0 {
                            child = Child(name: name, kind: .dir, device: st.st_dev,
                                          allocated: Int64(st.st_blocks) * 512, logical: Int64(st.st_size))
                        } else {
                            child = Child(name: name, kind: .dir, device: 0, allocated: 0, logical: 0)
                        }
                    case VLNK:
                        // A symlink is sized by the LINK, target never resolved (measure uses
                        // st_blocks for symlinks — mirror it exactly).
                        var st = stat()
                        if timedLstat(dirPath + "/" + name, &st, profile) == 0 {
                            child = Child(name: name, kind: .symlink, device: 0,
                                          allocated: Int64(st.st_blocks) * 512, logical: Int64(st.st_size))
                        } else {
                            child = Child(name: name, kind: .symlink, device: 0, allocated: 0, logical: 0)
                        }
                    default:
                        // Regular file (VREG) or a rare special node: a leaf. A regular file's
                        // size is inline in the bulk buffer (no extra syscall). A special node
                        // carries no file attrs; fall back to one lstat (st_blocks — the same
                        // measure() fallback for a non-symlink whose allocated size is unknown).
                        if hasFileSize {
                            child = Child(name: name, kind: .file, device: 0,
                                          allocated: allocSize, logical: dataLength)
                        } else {
                            var st = stat()
                            _ = timedLstat(dirPath + "/" + name, &st, profile)
                            child = Child(name: name, kind: .file, device: 0,
                                          allocated: Int64(st.st_blocks) * 512, logical: Int64(st.st_size))
                        }
                    }
                    out.append(child)
                }
                entry = entry.advanced(by: entryLen)
            }
        }
        return .complete(out)
    }
}
