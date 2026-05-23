import Testing
import EventKit
@testable import EAVCore

/// Tests for the CalendarAccess enum and its mapping from EKAuthorizationStatus.
///
/// The mapping lives in CalendarAccess.access(from:), which is a pure function
/// with no EventKit runtime dependency — safe to unit-test without a real EKEventStore.
@Suite("CalendarAccess mapping")
struct EventKitAccessTests {

    // MARK: - access(from:) mapping

    @Test(".fullAccess maps to .fullAccess")
    func fullAccessMapsToFullAccess() {
        #expect(CalendarAccess.access(from: .fullAccess) == .fullAccess)
    }

    @Test(".authorized maps to .fullAccess (pre-macOS 14 synonym)")
    func authorizedMapsToFullAccess() {
        // .authorized is the deprecated pre-macOS 14 case; semantically identical to .fullAccess.
        #expect(CalendarAccess.access(from: .authorized) == .fullAccess)
    }

    @Test(".writeOnly maps to .writeOnly")
    @available(macOS 14, *)
    func writeOnlyMapsToWriteOnly() {
        #expect(CalendarAccess.access(from: .writeOnly) == .writeOnly)
    }

    @Test(".denied maps to .denied")
    func deniedMapsToDenied() {
        #expect(CalendarAccess.access(from: .denied) == .denied)
    }

    @Test(".restricted maps to .denied")
    func restrictedMapsToDenied() {
        #expect(CalendarAccess.access(from: .restricted) == .denied)
    }

    @Test(".notDetermined maps to .denied")
    func notDeterminedMapsToDenied() {
        #expect(CalendarAccess.access(from: .notDetermined) == .denied)
    }

    // MARK: - canRead / canWrite helpers

    @Test("fullAccess can read and write")
    func fullAccessCanReadAndWrite() {
        #expect(CalendarAccess.fullAccess.canRead == true)
        #expect(CalendarAccess.fullAccess.canWrite == true)
    }

    @Test("writeOnly cannot read but can write")
    func writeOnlyCannotReadButCanWrite() {
        #expect(CalendarAccess.writeOnly.canRead == false)
        #expect(CalendarAccess.writeOnly.canWrite == true)
    }

    @Test("denied cannot read or write")
    func deniedCannotReadOrWrite() {
        #expect(CalendarAccess.denied.canRead == false)
        #expect(CalendarAccess.denied.canWrite == false)
    }

    // MARK: - Round-trip: access(from:) → canRead / canWrite

    @Test("fullAccess status round-trips to canRead=true canWrite=true")
    func fullAccessStatusRoundTrip() {
        let access = CalendarAccess.access(from: .fullAccess)
        #expect(access.canRead == true)
        #expect(access.canWrite == true)
    }

    @Test("writeOnly status round-trips to canRead=false canWrite=true")
    @available(macOS 14, *)
    func writeOnlyStatusRoundTrip() {
        let access = CalendarAccess.access(from: .writeOnly)
        #expect(access.canRead == false)
        #expect(access.canWrite == true)
    }

    @Test("denied status round-trips to canRead=false canWrite=false")
    func deniedStatusRoundTrip() {
        let access = CalendarAccess.access(from: .denied)
        #expect(access.canRead == false)
        #expect(access.canWrite == false)
    }
}
