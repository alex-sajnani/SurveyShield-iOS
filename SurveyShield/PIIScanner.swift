import Foundation
import OpenMedKit

class PIIScanner {
    /// MLX snapshot of the OpenMed PII model, downloaded to the local cache on first scan.
    static let modelRepoID = "OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1-mlx"

    private let policy: RedactionPolicy
    private var openmed: OpenMed?

    init(policy: RedactionPolicy = .buildDefault()) {
        self.policy = policy
    }

    /// Lazily downloads the model and creates the OpenMed runtime.
    /// Initialization is async (the model may need to be fetched), so it can't happen in `init`.
    private func loadOpenMedIfNeeded() async -> OpenMed? {
        if let openmed {
            return openmed
        }

        do {
            let modelDirectory = try await OpenMedModelStore.downloadMLXModel(
                repoID: Self.modelRepoID
            )
            let openmed = try OpenMed(backend: .mlx(modelDirectoryURL: modelDirectory))
            self.openmed = openmed
            return openmed
        } catch {
            print("OpenMed initialization failed: \(error)")
            return nil
        }
    }

    func scan(_ text: String) async -> RedactionResult {
        let entities = await detectEntitiesWithOpenMed(in: text)
        let (redactedText, reviewFlagged) = redactEntities(in: text, entities: entities)

        return RedactionResult(
            originalText: text,
            redactedText: redactedText,
            entities: entities,
            reviewFlagged: reviewFlagged
        )
    }

    private func detectEntitiesWithOpenMed(in text: String) async -> [PIIEntity] {
        guard let openmed = await loadOpenMedIfNeeded() else { return [] }

        do {
            // Drop entities below the review threshold; anything weaker is noise
            // that would neither be redacted nor flagged.
            let predictions = try openmed.extractPII(
                text,
                confidenceThreshold: Float(policy.reviewThreshold)
            )

            // Bracketed spans like "[date]" are placeholders from a previous
            // redaction pass; entities detected inside them must not be flagged again.
            let placeholderRanges = bracketedRanges(in: text)

            return predictions.compactMap { entity in
                if policy.suppressedLabels.contains(entity.label) {
                    return nil
                }

                let insidePlaceholder = placeholderRanges.contains { range in
                    range.lowerBound <= entity.start && entity.end <= range.upperBound
                }
                if insidePlaceholder {
                    return nil
                }

                return PIIEntity(
                    label: entity.label,
                    text: entity.text,
                    confidence: Double(entity.confidence),
                    start: entity.start,
                    end: entity.end
                )
            }
        } catch {
            print("PII extraction failed: \(error)")
            return []
        }
    }

    /// Character-offset ranges of bracketed spans like "[date]", including the brackets.
    /// Internal (not private) so unit tests can exercise it via `@testable import`.
    func bracketedRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openOffset: Int?

        for (offset, character) in text.enumerated() {
            if character == "[" {
                openOffset = offset
            } else if character == "]", let start = openOffset {
                ranges.append(start..<(offset + 1))
                openOffset = nil
            }
        }

        return ranges
    }

    /// Internal (not private) so unit tests can exercise redaction and review-flag
    /// routing without loading the on-device model via `@testable import`.
    func redactEntities(in text: String, entities: [PIIEntity]) -> (String, Bool) {
        var redactedText = text
        var reviewFlagged = false

        for entity in entities.sorted(by: { $0.start > $1.start }) {
            if entity.confidence >= policy.autoRedactThreshold {
                let method = policy.methodByLabel[entity.label] ?? policy.defaultMethod
                let replacement = redactionPlaceholder(for: entity.label, method: method)

                let start = redactedText.index(redactedText.startIndex, offsetBy: entity.start)
                let end = redactedText.index(start, offsetBy: entity.end - entity.start)
                redactedText.replaceSubrange(start..<end, with: replacement)
            } else if entity.confidence >= policy.reviewThreshold {
                // Confident enough to matter but not enough to auto-redact:
                // flag the response for human review.
                reviewFlagged = true
            }
        }

        return (redactedText, reviewFlagged)
    }

    func redactionPlaceholder(for label: String, method: String) -> String {
        switch method {
        case "mask":
            return "[\(label)]"
        case "hash":
            return "[\(label)-hash]"
        case "replace":
            return "[REDACTED]"
        default:
            return "[\(label)]"
        }
    }
}
