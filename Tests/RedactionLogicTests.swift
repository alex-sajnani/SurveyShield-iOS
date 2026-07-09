import XCTest
@testable import SurveyShield

/// Mirrors `tests/test_redact.py` and `tests/test_review.py` from the Python
/// package. The on-device OpenMed model needs a large download and a real
/// inference run, so — like the Python suite's fake `openmed` module — these
/// tests exercise the pure routing logic directly by feeding pre-built
/// `PIIEntity` values into `PIIScanner.redactEntities`. No model is loaded.
final class RedactionLogicTests: XCTestCase {

    /// Builds an entity whose character offsets point at `substring` inside `text`,
    /// so redaction's index math operates on real positions.
    private func entity(
        _ substring: String,
        label: String,
        confidence: Double,
        in text: String
    ) -> PIIEntity {
        guard let range = text.range(of: substring) else {
            fatalError("substring \(substring) not found in test text")
        }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        return PIIEntity(label: label, text: substring, confidence: confidence, start: start, end: end)
    }

    private func scanner(auto: Double, review: Double) -> PIIScanner {
        let policy = RedactionPolicy(
            methodByLabel: ["email": "mask", "first_name": "mask"],
            defaultMethod: "mask",
            autoRedactThreshold: auto,
            reviewThreshold: review,
            suppressedLabels: []
        )
        return PIIScanner(policy: policy)
    }

    func testHighConfidenceEntityGetsRedacted() {
        let text = "Please email me at jane@example.com about the results."
        let e = entity("jane@example.com", label: "email", confidence: 0.9, in: text)
        let (redacted, flagged) = scanner(auto: 0.75, review: 0.55).redactEntities(in: text, entities: [e])
        XCTAssertFalse(redacted.contains("jane@example.com"))
        XCTAssertTrue(redacted.contains("[email]"))
        XCTAssertFalse(flagged)
    }

    func testEntityBetweenThresholdsIsFlaggedNotRedacted() {
        let text = "Call John about the results."
        let e = entity("John", label: "first_name", confidence: 0.60, in: text)
        let (redacted, flagged) = scanner(auto: 0.75, review: 0.55).redactEntities(in: text, entities: [e])
        XCTAssertEqual(redacted, text, "below auto-redact threshold, text must be untouched")
        XCTAssertTrue(flagged, "above review threshold, response should be flagged")
    }

    func testEntityBelowReviewThresholdIsIgnored() {
        let text = "Call John about the results."
        let e = entity("John", label: "first_name", confidence: 0.40, in: text)
        let (redacted, flagged) = scanner(auto: 0.75, review: 0.55).redactEntities(in: text, entities: [e])
        XCTAssertEqual(redacted, text)
        XCTAssertFalse(flagged)
    }

    func testTextWithNoEntitiesIsUnchanged() {
        let text = "No complaints today."
        let (redacted, flagged) = scanner(auto: 0.75, review: 0.55).redactEntities(in: text, entities: [])
        XCTAssertEqual(redacted, text)
        XCTAssertFalse(flagged)
    }

    func testMultipleEntitiesAreAllRedacted() {
        let text = "Jane emailed jane@example.com yesterday."
        let name = entity("Jane", label: "first_name", confidence: 0.9, in: text)
        let email = entity("jane@example.com", label: "email", confidence: 0.9, in: text)
        // Redaction sorts by descending start internally, so order here shouldn't matter.
        let (redacted, _) = scanner(auto: 0.75, review: 0.55).redactEntities(in: text, entities: [name, email])
        XCTAssertFalse(redacted.contains("jane@example.com"))
        XCTAssertFalse(redacted.contains("Jane"))
        XCTAssertTrue(redacted.contains("[email]"))
        XCTAssertTrue(redacted.contains("[first_name]"))
    }

    // MARK: - Placeholder mapping

    func testRedactionPlaceholderMapsEachMethod() {
        let scanner = PIIScanner()
        XCTAssertEqual(scanner.redactionPlaceholder(for: "email", method: "mask"), "[email]")
        XCTAssertEqual(scanner.redactionPlaceholder(for: "email", method: "hash"), "[email-hash]")
        XCTAssertEqual(scanner.redactionPlaceholder(for: "email", method: "replace"), "[REDACTED]")
        XCTAssertEqual(scanner.redactionPlaceholder(for: "email", method: "unknown"), "[email]")
    }

    // MARK: - Bracketed placeholder detection

    func testBracketedRangesDetectsPlaceholders() {
        let scanner = PIIScanner()
        let ranges = scanner.bracketedRanges(in: "Seen on [date] at the clinic.")
        XCTAssertEqual(ranges.count, 1)
        // "[date]" starts at offset 8 and the closing bracket is at 13, so range is 8..<14.
        XCTAssertEqual(ranges.first?.lowerBound, 8)
        XCTAssertEqual(ranges.first?.upperBound, 14)
    }

    func testBracketedRangesReturnsEmptyWhenNoBrackets() {
        XCTAssertTrue(PIIScanner().bracketedRanges(in: "plain text, no brackets").isEmpty)
    }
}
