import SwiftUI

@main
struct SurveyShieldApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Theme

/// Palette matching the SurveyJS-style template: teal brand color, light gray
/// page background, white question cards, and muted gray borders.
private enum Theme {
    static let accent = Color(red: 0.10, green: 0.70, blue: 0.58)
    static let pageBackground = Color(red: 0.95, green: 0.95, blue: 0.95)
    static let cardBackground = Color.white
    static let titleText = Color(red: 0.25, green: 0.25, blue: 0.25)
    static let valueText = Color(red: 0.25, green: 0.31, blue: 0.49)
    static let border = Color(red: 0.84, green: 0.84, blue: 0.84)
    static let fieldBackground = Color(red: 0.976, green: 0.976, blue: 0.976)
}

// MARK: - Reusable Styling

/// White rounded question card with a subtle drop shadow, as in the template.
private struct SurveyCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.cardBackground)
        .cornerRadius(4)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

// MARK: - Content View

struct ContentView: View {
    @State private var userResponse: String = ""
    @State private var redactionResult: RedactionResult? = nil
    @State private var scanner = PIIScanner()
    @State private var isScanning = false
    @State private var entitiesToRedact: Set<UUID> = []
    @FocusState private var responseFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(spacing: 16) {
                    responseCard(for: appleSurveyQuestion)

                    if let result = redactionResult {
                        resultCard(for: result)
                    }
                }
                .padding(16)
            }
            .background(Theme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    responseFieldFocused = false
                }
            }
        }
    }

    // MARK: Header

    /// White top bar with the teal brand chip and menu icons, as in the template.
    private var headerBar: some View {
        HStack(spacing: 24) {
            Text("SurveyShield")
                .font(.footnote.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.accent)
                .cornerRadius(3)

            Spacer()

            Image(systemName: "person")
            Image(systemName: "line.3.horizontal")
        }
        .foregroundColor(Theme.titleText)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.cardBackground)
        .overlay(alignment: .bottom) {
            Theme.border.frame(height: 0.5)
        }
    }

    // MARK: Response Input

    private func responseCard(for question: SurveyQuestion) -> some View {
        SurveyCard {
            Text(question.question)
                .font(.body.weight(.semibold))
                .foregroundColor(Theme.titleText)

            TextEditor(text: $userResponse)
                .focused($responseFieldFocused)
                .font(.body)
                .foregroundColor(Theme.valueText)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 140)
                .background(Theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Theme.border, lineWidth: 1)
                )

            Button(action: scanResponse) {
                Group {
                    if isScanning {
                        HStack {
                            ProgressView()
                                .tint(.white)
                            Text("Scanning...")
                        }
                    } else {
                        Text("Submit Response")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent)
                .foregroundColor(.white)
                .cornerRadius(3)
            }
            .disabled(userResponse.trimmingCharacters(in: .whitespaces).isEmpty || isScanning)
        }
    }

    // MARK: Scan Result

    private func resultCard(for result: RedactionResult) -> some View {
        SurveyCard {
            if result.entities.isEmpty {
                Label("All Clear", systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundColor(Theme.accent)

                Text("No personal information was detected. Your response has been submitted.")
                    .font(.body)
                    .foregroundColor(Theme.titleText)

                Button(action: clearResult) {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundColor(Theme.accent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.accent, lineWidth: 1)
                        )
                }
            } else {
                Label("Personal Information Detected", systemImage: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.orange)

                Text("Your response was not submitted. Please remove the information flagged below and resubmit.")
                    .font(.body)
                    .foregroundColor(Theme.titleText)

                ForEach(result.entities) { entity in
                    entityRow(for: entity)
                }

                Button(action: { redactAndResubmit(result) }) {
                    Text("Redact Selected & Resubmit")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(entitiesToRedact.isEmpty ? Theme.border : Theme.accent)
                        .foregroundColor(.white)
                        .cornerRadius(3)
                }
                .disabled(entitiesToRedact.isEmpty || isScanning)

                Button(action: reviseResponse) {
                    Text("Edit Response")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundColor(Theme.accent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.accent, lineWidth: 1)
                        )
                }
            }
        }
    }

    /// One flagged entity with a toggleable Redact button. When marked for
    /// redaction, the flagged text is shown struck through next to the
    /// placeholder that will replace it.
    private func entityRow(for entity: PIIEntity) -> some View {
        let isMarked = entitiesToRedact.contains(entity.id)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entity.label.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isMarked ? Theme.accent : Color.orange)
                    .cornerRadius(3)

                if isMarked {
                    Text("\"\(entity.text)\"")
                        .font(.body)
                        .strikethrough()
                        .foregroundColor(.secondary)
                    + Text("  \(redactionPlaceholder(for: entity))")
                        .font(.body.weight(.medium))
                        .foregroundColor(Theme.accent)
                } else {
                    Text("\"\(entity.text)\"")
                        .font(.body)
                        .foregroundColor(Theme.valueText)
                }
            }

            Spacer()

            Button(action: { toggleRedaction(of: entity) }) {
                Label(isMarked ? "Redacted" : "Redact",
                      systemImage: isMarked ? "checkmark" : "eye.slash")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isMarked ? Theme.accent : Theme.cardBackground)
                    .foregroundColor(isMarked ? .white : Theme.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.accent, lineWidth: 1)
                    )
                    .cornerRadius(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.fieldBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    // MARK: Actions

    private func toggleRedaction(of entity: PIIEntity) {
        if entitiesToRedact.contains(entity.id) {
            entitiesToRedact.remove(entity.id)
        } else {
            entitiesToRedact.insert(entity.id)
        }
    }

    private func redactionPlaceholder(for entity: PIIEntity) -> String {
        "[\(entity.label)]"
    }

    /// Replaces every entity marked for redaction with its placeholder and
    /// rescans the result. Replacements are applied back-to-front so earlier
    /// entity offsets stay valid.
    private func redactAndResubmit(_ result: RedactionResult) {
        var text = result.originalText
        let marked = result.entities
            .filter { entitiesToRedact.contains($0.id) }
            .sorted { $0.start > $1.start }

        for entity in marked {
            let start = text.index(text.startIndex, offsetBy: entity.start)
            let end = text.index(start, offsetBy: entity.end - entity.start)
            text.replaceSubrange(start..<end, with: redactionPlaceholder(for: entity))
        }

        userResponse = text
        scanResponse()
    }

    private func scanResponse() {
        responseFieldFocused = false
        isScanning = true
        entitiesToRedact = []
        Task {
            redactionResult = await scanner.scan(userResponse)
            isScanning = false
        }
    }

    private func clearResult() {
        userResponse = ""
        redactionResult = nil
        entitiesToRedact = []
    }

    /// Returns to editing while keeping the response text, so the user can
    /// remove the flagged information and resubmit.
    private func reviseResponse() {
        redactionResult = nil
        entitiesToRedact = []
        responseFieldFocused = true
    }
}

#Preview {
    ContentView()
}
