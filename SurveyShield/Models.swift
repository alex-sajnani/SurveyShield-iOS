import Foundation

// MARK: - Redaction Policy

struct RedactionPolicy {
    let methodByLabel: [String: String]
    let defaultMethod: String
    let autoRedactThreshold: Double
    let reviewThreshold: Double
    /// Model labels that are too low-value to flag (e.g. "time": durations
    /// like "30 minutes" are not identifying on their own).
    let suppressedLabels: Set<String>

    static func buildDefault() -> RedactionPolicy {
        // Labels match the OpenMed PII model vocabulary (snake_case, e.g.
        // "first_name", not "PERSON") — see id2label.json in the model artifact.
        RedactionPolicy(
            methodByLabel: [
                "first_name": "mask",
                "last_name": "mask",
                "email": "mask",
                "phone_number": "mask",
                "street_address": "mask",
                "city": "mask",
                "state": "mask",
                "postcode": "mask",
                "country": "mask",
                "company_name": "mask",
                "occupation": "mask",
                "date": "mask",
                "date_of_birth": "mask",
                "age": "mask",
                "ssn": "mask",
                "medical_record_number": "mask",
                "health_plan_beneficiary_number": "mask"
            ],
            defaultMethod: "mask",
            // Observed confidences on-device: phone numbers ~0.78, dates ~0.84.
            // 0.75 keeps those auto-redacted instead of merely review-flagged.
            autoRedactThreshold: 0.75,
            reviewThreshold: 0.55,
            suppressedLabels: ["time"]
        )
    }
}

// MARK: - PII Entity

struct PIIEntity: Identifiable {
    let id = UUID()
    let label: String
    let text: String
    let confidence: Double
    let start: Int
    let end: Int
}

// MARK: - Redaction Result

struct RedactionResult {
    let originalText: String
    let redactedText: String
    let entities: [PIIEntity]
    let reviewFlagged: Bool
}

// MARK: - Survey Question

struct SurveyQuestion: Identifiable, Hashable {
    let id: UUID
    let question: String
    let category: String

    init(question: String, category: String) {
        self.id = UUID()
        self.question = question
        self.category = category
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SurveyQuestion, rhs: SurveyQuestion) -> Bool {
        lhs.id == rhs.id
    }
}

let appleSurveyQuestion = SurveyQuestion(
    question: "How has your wearable impacted your daily fitness routine? Please do not include any personally identifiable information (e.g. names, addresses, dates) in your response.",
    category: "Fitness Tracking"
)
