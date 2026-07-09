import XCTest
@testable import SurveyShield

/// Mirrors `tests/test_policy.py` from the Python SurveyShield package.
/// The policy is the single source of truth for redaction decisions, so these
/// tests pin down its thresholds, label coverage, and override behaviour.
final class PolicyTests: XCTestCase {

    func testDefaultPolicyThresholds() {
        let policy = RedactionPolicy.buildDefault()
        // 0 < review < autoRedact < 1
        XCTAssertGreaterThan(policy.reviewThreshold, 0.0)
        XCTAssertLessThan(policy.reviewThreshold, policy.autoRedactThreshold)
        XCTAssertLessThan(policy.autoRedactThreshold, 1.0)
    }

    func testDefaultPolicyCoversCommonLabels() {
        let policy = RedactionPolicy.buildDefault()
        // Labels use the OpenMed PII vocabulary (snake_case), not "PERSON"/"EMAIL".
        for label in ["first_name", "last_name", "email", "phone_number", "street_address"] {
            XCTAssertNotNil(policy.methodByLabel[label], "expected policy to cover \(label)")
        }
    }

    func testUnknownLabelFallsBackToDefaultMethod() {
        let policy = RedactionPolicy.buildDefault()
        let method = policy.methodByLabel["some_new_label"] ?? policy.defaultMethod
        XCTAssertEqual(method, policy.defaultMethod)
    }

    func testDefaultMethodIsMaskForSafety() {
        XCTAssertEqual(RedactionPolicy.buildDefault().defaultMethod, "mask")
    }

    func testTimeLabelIsSuppressed() {
        // "time" (durations like "30 minutes") is not identifying on its own.
        XCTAssertTrue(RedactionPolicy.buildDefault().suppressedLabels.contains("time"))
    }

    func testPolicyIsOverridable() {
        let policy = RedactionPolicy(
            methodByLabel: ["email": "replace"],
            defaultMethod: "mask",
            autoRedactThreshold: 0.99,
            reviewThreshold: 0.1,
            suppressedLabels: []
        )
        XCTAssertEqual(policy.autoRedactThreshold, 0.99)
        XCTAssertEqual(policy.reviewThreshold, 0.1)
        XCTAssertEqual(policy.methodByLabel["email"], "replace")
    }
}
