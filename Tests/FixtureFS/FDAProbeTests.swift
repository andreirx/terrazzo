//
//  FDAProbeTests.swift — the pure FDA-probe classifier (TZ-4 D10).
//  Module maturity: PROTOTYPE (slice TZ-4)
//
//  `FDAProbe.classify` is the PURE interpretation of a probe directory-listing attempt
//  (the syscall itself, `probe()`, is not unit-tested — it depends on the machine's TCC
//  state; packet D8 asks for the "pure part"). A sum type of three outcomes:
//   - listed successfully                     ⇒ granted (FDA present or not required)
//   - failed with EPERM/EACCES                ⇒ denied  (warrants the banner)
//   - failed otherwise (ENOENT / nil / other) ⇒ indeterminate (no false alarm — the
//                                                scan's own denied tiles stay the signal)
//

import XCTest
import ScanFS
import Darwin

final class FDAProbeTests: XCTestCase {

    func testListedIsGranted() {
        XCTAssertEqual(FDAProbe.classify(listed: true, posixError: nil), .granted)
    }

    func testPermissionErrorsAreDenied() {
        XCTAssertEqual(FDAProbe.classify(listed: false, posixError: Int32(EPERM)), .denied)
        XCTAssertEqual(FDAProbe.classify(listed: false, posixError: Int32(EACCES)), .denied)
    }

    func testMissingPathIsIndeterminate() {
        // Mail never configured ⇒ ENOENT ⇒ do NOT raise a false FDA alarm.
        XCTAssertEqual(FDAProbe.classify(listed: false, posixError: Int32(ENOENT)), .indeterminate)
    }

    func testUnknownAndNilErrorsAreIndeterminate() {
        XCTAssertEqual(FDAProbe.classify(listed: false, posixError: nil), .indeterminate)
        XCTAssertEqual(FDAProbe.classify(listed: false, posixError: Int32(EIO)), .indeterminate)
    }
}
