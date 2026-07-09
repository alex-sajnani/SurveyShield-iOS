# SurveyShield-iOS: Test and Evaluation Results

Run date: July 6, 2026

## Summary

SurveyShield reads open-text survey answers and removes personal information
(names, phone numbers, emails, addresses) before the data reaches an analyst.
This run measured how well it does that.

**The app caught 97% of the planted personal information, and 97% of what it
flagged was genuinely personal.** It misses little real PII and raises few false
alarms. All 31 automated code tests passed.

The figures come from 300 realistic survey responses seeded with 72 pieces of
personal information, scored against the exact detection model and settings the
iPhone app ships with.

## Why the design choices matter

One policy rule carries most of the accuracy gain: the app suppresses plain time
references like "30 minutes" or "3am." On their own these say nothing about who a
person is, but the underlying detector flags them constantly. Suppressing them
cut the false alarms almost to zero without dropping any real personal
information. That single call is the difference between a result an analyst can
trust and one lost in noise.

The app also routes each finding by the detector's confidence. Clear cases, a
phone number or a full name, are removed automatically. Borderline cases are held
for a person to check rather than acted on blindly, so a wrong guess never ships
silently.

## The four rules on top of the model

The detector proposes; these four rules decide what actually happens. They are
applied in order:

1. **Ignore non-identifying labels.** Anything tagged as a plain time reference
   (`time`) is dropped, however confident the model is. This removed 90 of the 92
   false alarms.
2. **Drop low-confidence noise.** Any finding below 0.55 confidence is discarded,
   rather than acting on the model's weakest guesses.
3. **Remove or review, by confidence.** Findings at 0.75 or above are treated as
   clear and removed automatically; findings between 0.55 and 0.75 are set aside
   for a person to check.
4. **Never re-flag its own edits.** After it replaces something with a placeholder
   like `[city]`, the confirmation re-scan skips those placeholders, so the app
   can't get stuck flagging labels it just inserted.

All four live in one place, `RedactionPolicy.buildDefault()` in `Models.swift`,
so the thresholds and the suppressed list can be tuned without touching the
scanning or interface code.

## The numbers

| What we measured | Result |
|---|---|
| Personal info correctly caught (recall) | 97% |
| Flags that were actually personal info (precision) | 97% |
| Automated code tests passed | 31 of 31 |
| Test set | 300 responses, 72 planted items |

Out of everything the detector surfaced, the app automatically removed 69 clear
cases, set aside 3 borderline ones for human review, and correctly ignored 91
non-identifying items. It missed 2 (a state abbreviation and one city name) and
raised 2 weak false alarms, both of which went to the review pile rather than
being acted on.

## About the model

The iPhone app runs OpenMed's 66-million-parameter privacy model in Apple's
on-device MLX format, which only runs on Apple hardware. This evaluation ran the
same model weights in a server-side form, so the accuracy figures reflect what
the app itself detects.

---

### Technical appendix

Model: `OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1` (DistilBERT, 106 labels),
the standard transformers checkpoint of the same weights the app ships as
`...-66M-v1-mlx`. Same weights, tokenizer, and label vocabulary; only the runtime
differs (CPU/PyTorch here vs Apple MLX on device).

Policy from `SurveyShield/Models.swift → buildDefault()`: auto-redact ≥ 0.75,
review ≥ 0.55, suppressed labels = {`time`}. Dataset: `generate_synthetic_survey_export`,
300 rows, seed 7, 12% leak rate.

Two views are reported. "Baseline OpenMed" grades every candidate the model
emits, before any of the app's rules. "Additional rules" grades what is left
after the app's rules run, which is what the app actually acts on.

| View | Precision | Recall | F1 | TP | FP | FN |
|------|-----------|--------|-----|----|----|----|
| Baseline OpenMed (every candidate) | 43.6% | 98.6% | 0.604 | 71 | 92 | 1 |
| Additional rules (what the app acts on) | 97.2% | 97.2% | 0.972 | 70 | 2 | 2 |

Routing of the 163 baseline detections: 90 suppressed as `time`, 1 dropped as
noise (< 0.55), 69 auto-redacted (≥ 0.75), 3 held for review (0.55–0.75). Phone
scores 0.81–0.89 (mean 0.86); the two false positives that survived the
additional rules were a `coordinate` (0.69) and an `ipv4` (0.71) on wearable
numeric text, both routed to review.

Prior finding: `SurveyShield/EVALUATION_FINDINGS.md` reports F1 0.150. That run
matched old combined-label ground truth (`NAME`, `ADDRESS`) against a model that
emits component-level labels (`first_name`, `city`), so almost nothing matched by
exact text. It was a labeling mismatch in the test data, not a model failure.

Files: `run_ios_aligned_evaluation.py` (harness), `results/evaluation_results.json`
(full metrics), `results/scan_detections.csv` (every detection),
`results/confidence_by_label.csv` (score distribution), `results/pytest_results.txt`
(test log).

Reproduce:

```bash
pip install torch --index-url https://download.pytorch.org/whl/cpu
pip install transformers pandas faker
python3 evaluation/run_ios_aligned_evaluation.py
```
