# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Start

```bash
# Open in Xcode
open SurveyShield.xcodeproj

# Run the app on iOS Simulator (or use Cmd+R in Xcode)
xcodebuild -scheme SurveyShield -destination 'platform=iOS Simulator,name=iPhone 16'

# Run unit tests
xcodebuild test -scheme SurveyShield -destination 'platform=iOS Simulator,name=iPhone 16'

# Run a single test class
xcodebuild test -scheme SurveyShield -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SurveyShield/RedactionLogicTests

# Run a single test method
xcodebuild test -scheme SurveyShield -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SurveyShield/RedactionLogicTests/testHighConfidenceEntityGetsRedacted
```

## Requirements

- **Xcode 15+**: Required for Swift 5.9 and iOS 17 deployment target support.
- **iOS 17+**: OpenMedKit targets iOS 17 as the minimum deployment target.
- **Apple Silicon Mac**: The MLX runtime (Apple's machine learning framework) requires native execution on Apple Silicon; Simulator builds on Intel Macs will fail at model load time.

## Architecture

The app implements a four-stage scan-and-redact pipeline, each with a clear responsibility:

| Stage | Component | File | Purpose |
|-------|-----------|------|---------|
| **Capture** | `ContentView` (SwiftUI) | `SurveyShieldApp.swift` | Survey form, submission, and redaction UI |
| **Detection** | `detectEntitiesWithOpenMed` in `PIIScanner` | `PIIScanner.swift` | On-device inference via OpenMedKit |
| **Decision** | `RedactionPolicy` + `redactEntities` | `Models.swift` + `PIIScanner.swift` | Route detections by confidence score |
| **Execution** | Span-level replacement with placeholders | `SurveyShieldApp.swift` + `PIIScanner.swift` | Replace only the identified span |

### Data Flow

1. **User enters text** in the `TextEditor` → Submit button enables.
2. **Submit triggers scan**: `PIIScanner.scan()` calls OpenMedKit's `extractPII()`.
3. **Model loads (first time only)**: `OpenMedModelStore.downloadMLXModel()` downloads the 66M-parameter PII model to the local cache; subsequent scans run offline.
4. **Entities filtered and routed**:
   - Confidence ≥ 0.75 (auto-redact threshold): offered for one-tap redaction.
   - 0.55 ≤ confidence < 0.75 (review tier): blocks submission, shown to user for review.
   - Confidence < 0.55: treated as noise, discarded.
   - Labels in `suppressedLabels` (e.g., "time"): filtered out even if high-confidence.
5. **User redacts** by toggling entities and tapping "Redact Selected & Resubmit".
6. **Text replaced** span-by-span using character offsets from the scan.
7. **Re-scan for confirmation**: runs `extractPII()` again; any detected placeholders are skipped by offset so the confirmation reflects only the user's original text.
8. **Submit when clean**: re-scan comes back empty → "All Clear" screen.

## Key Design Decisions

### 1. Confidence Drives Routing, Not Label Alone

The model returns a confidence score (0–1) with every entity. The `RedactionPolicy` carries two thresholds:
- **0.75 (auto-redact)**: Observed on-device confidences for phone numbers (~0.78) and dates (~0.84) sit in this tier, so they are offered for one-tap removal without requiring human review.
- **0.55 (review)**: Weaker detections still matter (false negatives are worse than false positives for PII), so they block submission but are held for a person to inspect, not auto-redacted.

This is set in `RedactionPolicy.buildDefault()` in `Models.swift`. If detection accuracy improves or deployment context changes, adjust these thresholds without touching scan or UI code.

### 2. Redaction is Span-Level, Not Whole-Response

Only the identified identifier is replaced using its exact character offsets (`start` and `end` on `PIIEntity`). A response like `"...my gym in SF..."` becomes `"...my gym in [city]..."`, leaving the context intact so the survey content remains usable for analysis.

### 3. Re-Scan Cannot Re-Flag Its Own Placeholders

After redaction, a second scan confirms the text is clean. Placeholders like `[date]` are bracketed, and `PIIScanner.bracketedRanges()` detects their offsets. Any entity detected inside a bracketed range is skipped (line 67–72 of `PIIScanner.swift`), so the confirmation pass reflects only what the model finds in the participant's own words, not the app's inserted labels.

### 4. OpenMedKit is Vendored, Not Fetched

The framework lives under `Vendor/OpenMedKit` instead of being pulled via Swift Package Manager because the upstream manifest omitted the `resources:` declaration needed for `Bundle.module` to load policy files. Vendoring ensures reproducible builds. Once upstream ships the fix, the plan is to drop the copy and point back to the remote package.

## Core Files

- **[SurveyShieldApp.swift](SurveyShield/SurveyShieldApp.swift)**: Entry point, main `ContentView`, survey UI, and redaction flow. Contains the full state machine for the four screens (survey form, PII detected card, redaction toggles, all-clear confirmation).

- **[PIIScanner.swift](SurveyShield/PIIScanner.swift)**: Scan orchestration. Lazy-loads the model, calls `OpenMed.extractPII()`, applies the policy, filters by suppressed labels and bracketed spans, and routes detections to redaction or review.

- **[Models.swift](SurveyShield/Models.swift)**: `RedactionPolicy` (thresholds and label-to-method map), `PIIEntity` (a single detection with label, offsets, and confidence), `RedactionResult` (the output of a scan), and `SurveyQuestion` (survey metadata).

- **Tests/**: Three test suites exercising redaction logic, policy, and models in isolation (without loading the actual model):
  - [RedactionLogicTests.swift](Tests/RedactionLogicTests.swift): Confidence-based routing, span-level redaction, and placeholder detection. Most comprehensive.
  - [PolicyTests.swift](Tests/PolicyTests.swift): Policy initialization and label mapping.
  - [ModelsTests.swift](Tests/ModelsTests.swift): Data model behavior.

## Important Implementation Details

### Model Download and Caching

The app pins `OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1-mlx` (66M parameters). On the first scan, `OpenMedModelStore.downloadMLXModel()` fetches the model snapshot to `~/Library/Caches` and caches it. Subsequent scans use the cached copy, so the app runs fully offline after the first download.

### Lazy Model Load

The model is not initialized in `AppDelegate` or at app startup. Instead, `PIIScanner.loadOpenMedIfNeeded()` loads it asynchronously on the first scan attempt. This avoids blocking the UI on launch and allows graceful error handling if initialization fails (returns `nil`, and the scan returns an empty entity list).

### Confidence Observations

Real on-device detection runs have produced:
- Phone numbers: ~0.78 confidence
- Dates: ~0.84 confidence

These observations informed the choice of 0.75 as the auto-redact threshold.

### Suppressed Labels

The `suppressedLabels` set in `RedactionPolicy` holds entity types that have no identifying value on their own:
- `time`: Durations like "30 minutes" are not PII on their own and clutter the review tier.

If other labels prove low-value in deployment, add them here.

### Entity Filtering Pipeline

After `extractPII()` returns detections, the app filters in this order:
1. Confidence check: drop anything below `reviewThreshold` (0.55).
2. Label check: drop anything in `suppressedLabels`.
3. Placeholder check: drop anything whose offsets fall inside a bracketed span from a previous pass.

## Testing Philosophy

Tests are written to exercise logic **without loading the on-device model**. The suite mirrors the Python package's approach:
- Tests feed pre-built `PIIEntity` values directly to `PIIScanner.redactEntities()` and `bracketedRanges()`.
- This allows fast iteration on policy and routing logic in CI/CD without downloading the large model.
- The model inference itself is tested by OpenMedKit's own suite under `Vendor/OpenMedKit/Tests/OpenMedKitTests`.

Key test patterns:
- Use the `entity()` helper to build test entities with realistic character offsets.
- Parameterize thresholds via `scanner(auto:review:)` to test boundary cases.
- Verify both the redacted text and the `reviewFlagged` boolean.

## Deployment Context

This app is the on-device screening phase of the larger SurveyShield project. It screens a wearable fitness survey but generalizes to any open-text survey. See [PRD.md](PRD.md) for the full product context and roadmap (multi-language screening, active-learning review loop, regulatory policy profiles).

## Roadmap

Planned next steps (from [PRD.md](PRD.md)):

1. **Multi-language screening**: Extend detection to OpenMed's supported PII language codes with per-site policy.
2. **Active-learning review loop**: Log redaction decisions and recalibrate the review threshold over time.
3. **Named regulatory profiles**: Surface OpenMedKit's bundled policies (HIPAA Safe Harbor, GDPR, PIPEDA, etc.) as selectable options.

## Evaluation Harness

`evaluation/run_ios_aligned_evaluation.py` measures detection accuracy against 300 synthetic survey responses (72 planted identifiers), using the same model weights and `RedactionPolicy` thresholds as the app. It runs on the transformers checkpoint (`OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1`) rather than the MLX build, since MLX cannot execute off Apple Silicon — same weights and tokenizer, so results carry over. Results and methodology are in [evaluation/RESULTS.md](evaluation/RESULTS.md); if `RedactionPolicy.buildDefault()` thresholds or `suppressedLabels` change, this harness should be re-run.

## Resources

- **README.md**: Feature overview, setup, and architecture summary.
- **PRD.md**: Product requirements and design objectives.
- **OpenMed NER Paper**: https://arxiv.org/abs/2508.01630
- **OpenMedKit Repository**: https://github.com/maziyarpanahi/openmed/tree/master/swift/OpenMedKit
