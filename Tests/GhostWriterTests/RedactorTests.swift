import XCTest
@testable import GhostWriter

/// Unit tests for `Redactor` — the opt-in scrub of sensitive tokens applied at
/// the single transcription choke point. Because redaction reads live
/// `AppSettings`, each test snapshots and restores the relevant flags.
/// Fixtures use obviously-fake placeholder values.
final class RedactorTests: XCTestCase {

    private var saved: (Bool, Bool, Bool, Bool) = (false, false, false, false)

    override func setUp() {
        super.setUp()
        let s = AppSettings.shared
        saved = (s.redactionEnabled, s.redactEmails, s.redactNumbers, s.redactPhones)
    }

    override func tearDown() {
        let s = AppSettings.shared
        (s.redactionEnabled, s.redactEmails, s.redactNumbers, s.redactPhones) = saved
        super.tearDown()
    }

    private func enable(emails: Bool = false, numbers: Bool = false, phones: Bool = false) {
        let s = AppSettings.shared
        s.redactionEnabled = true
        s.redactEmails = emails
        s.redactNumbers = numbers
        s.redactPhones = phones
    }

    func testDisabledPassesTextThrough() {
        AppSettings.shared.redactionEnabled = false
        let input = "Reach me at ada@example.com or 555-234-5678."
        XCTAssertEqual(Redactor.redact(input), input)
    }

    func testRedactsEmail() {
        enable(emails: true)
        let out = Redactor.redact("Ping ada.lovelace@example.co.uk please")
        XCTAssertEqual(out, "Ping [redacted email] please")
    }

    func testRedactsLongDigitRunAsNumber() {
        enable(numbers: true)
        // 16-digit card-like run.
        let out = Redactor.redact("Card 4111 1111 1111 1111 on file")
        XCTAssertTrue(out.contains("[redacted number]"))
        XCTAssertFalse(out.contains("4111"))
    }

    func testRedactsPhone() {
        enable(phones: true)
        let out = Redactor.redact("Call +1 (555) 234-5678 tomorrow")
        XCTAssertTrue(out.contains("[redacted phone]"))
        XCTAssertFalse(out.contains("5678"))
    }

    func testOnlyEnabledCategoriesAreRedacted() {
        enable(emails: true)   // phones/numbers off
        let out = Redactor.redact("ada@example.com / 555-234-5678")
        XCTAssertTrue(out.contains("[redacted email]"))
        XCTAssertTrue(out.contains("555-234-5678"))   // phone left intact
    }

    func testShortDigitRunNotTreatedAsCardNumber() {
        enable(numbers: true)   // phones off, so a short run isn't caught by either
        let out = Redactor.redact("Room 402 at 9am")
        XCTAssertEqual(out, "Room 402 at 9am")
    }
}
