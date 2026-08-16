//
//  FDAProbe.swift — Full Disk Access detection (I/O probe + pure classification).
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  THE GUIDED FLOW (TZ-4 deliverable 5). Terrazzo is unsandboxed so it can see the disk
//  (VISION §"What it is NOT"), but macOS TCC still gates a set of protected locations
//  behind Full Disk Access. Without FDA a volume-root scan renders large swaths as
//  DENIED tiles; WITH it the map is honest. So at scan start we PROBE a known
//  TCC-protected path; if denied while mapping a whole volume, the App shows a
//  non-modal banner explaining FDA and offering to open the System Settings pane.
//  NEVER blocks scanning — the scan proceeds regardless; denied dirs just render denied.
//
//  SPLIT (testability, CLAUDE.md constraint 1): `probe()` does the syscall; `classify`
//  is the PURE interpretation of its outcome (packet deliverable 8: "FDA-probe logic
//  (pure part)" tested). All the filesystem access lives in ScanFS.
//
//  PROBE TARGET: `~/Library/Mail` — a first-party TCC-protected directory present on a
//  normally-configured Mac. Listing it succeeds under FDA and fails with EPERM/EACCES
//  without it. If it does not exist (Mail never configured), the probe is INDETERMINATE
//  — we do NOT raise a false alarm; the denied tiles the scan itself produces remain the
//  honest signal.
//

import Foundation
import Darwin // errno codes for the pure classifier

/// The FDA state a probe implies. A sum type: three mutually-exclusive outcomes, so the
/// App's banner logic is an exhaustive decision, not a bool-plus-nullable.
public enum FDAStatus: Sendable, Equatable {
    /// The protected path listed successfully — FDA is granted (or not required here).
    case granted
    /// Listing failed with a permission error — FDA is denied; the banner is warranted.
    case denied
    /// Neither confirmed (path absent, or a non-permission error) — no banner; the
    /// scan's own denied tiles remain the truthful signal.
    case indeterminate
}

public enum FDAProbe {
    /// The TCC-protected probe path (`~/Library/Mail`).
    public static var protectedProbePath: String { NSHomeDirectory() + "/Library/Mail" }

    /// PURE: interpret a listing attempt. `listed` is whether the directory enumeration
    /// succeeded; `posixError` is the POSIX errno if it failed (`nil` on success).
    /// EPERM/EACCES ⇒ denied; anything else (including ENOENT) ⇒ indeterminate.
    public static func classify(listed: Bool, posixError: Int32?) -> FDAStatus {
        if listed { return .granted }
        switch posixError {
        case Int32(EPERM), Int32(EACCES): return .denied
        default: return .indeterminate
        }
    }

    /// Probe the protected path (one directory listing) and classify the result. The
    /// only syscall; returns an `FDAStatus`. Reading a directory we may lack permission
    /// for is exactly the TCC gate we are testing — the failure IS the datum.
    public static func probe(path: String = protectedProbePath) -> FDAStatus {
        var listed = false
        var errCode: Int32?
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            listed = true
        } catch let e as NSError {
            // Foundation wraps POSIX errors as NSPOSIXErrorDomain with errno as code.
            errCode = e.domain == NSPOSIXErrorDomain ? Int32(e.code) : Int32(EPERM)
            // A Cocoa "no permission" error (513) also means denied — normalize it.
            if e.domain == NSCocoaErrorDomain && e.code == 513 { errCode = Int32(EACCES) }
            // A Cocoa "file doesn't exist" (260) means indeterminate — normalize to ENOENT.
            if e.domain == NSCocoaErrorDomain && e.code == 260 { errCode = Int32(ENOENT) }
        }
        return classify(listed: listed, posixError: errCode)
    }
}
