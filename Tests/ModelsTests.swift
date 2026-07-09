import XCTest
@testable import SurveyShield

/// Covers the value types in `Models.swift`: identity/equality semantics and
/// the shipped survey question. These have no Python counterpart (the iOS app
/// carries its own presentation models) but round out the starter suite.
final class ModelsTests: XCTestCase {

    func testSurveyQuestionEqualityIsByIdentity() {
        let a = SurveyQuestion(question: "Same text?", category: "Fitness")
        let b = SurveyQuestion(question: "Same text?", category: "Fitness")
        // Distinct instances get distinct ids, so equal text does not make them equal.
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a)
    }

    func testSurveyQuestionHashesByIdentity() {
        let q = SurveyQuestion(question: "Hashable?", category: "Fitness")
        let set: Set<SurveyQuestion> = [q, q]
        XCTAssertEqual(set.count, 1)
    }

    func testAppleSurveyQuestionContent() {
        XCTAssertEqual(appleSurveyQuestion.category, "Fitness Tracking")
        XCTAssertTrue(appleSurveyQuestion.question.contains("wearable"))
    }

    func testPIIEntityStoresFields() {
        let e = PIIEntity(label: "email", text: "a@b.com", confidence: 0.9, start: 3, end: 10)
        XCTAssertEqual(e.label, "email")
        XCTAssertEqual(e.text, "a@b.com")
        XCTAssertEqual(e.confidence, 0.9)
        XCTAssertEqual(e.start, 3)
        XCTAssertEqual(e.end, 10)
    }

    func testRedactionResultStoresFields() {
        let entities = [PIIEntity(label: "email", text: "a@b.com", confidence: 0.9, start: 0, end: 7)]
        let result = RedactionResult(
            originalText: "a@b.com here",
            redactedText: "[email] here",
            entities: entities,
            reviewFlagged: false
        )
        XCTAssertEqual(result.originalText, "a@b.com here")
        XCTAssertEqual(result.redactedText, "[email] here")
        XCTAssertEqual(result.entities.count, 1)
        XCTAssertFalse(result.reviewFlagged)
    }
}
