#!/usr/bin/env python3
"""iOS-aligned evaluation of SurveyShield using the REAL 66M OpenMed model.

This runs the SurveyShield Python evaluation suite (synthetic data -> scan ->
policy routing -> ground-truth grading) but wired to the *actual* OpenMed PII
model that the SurveyShield-iOS app ships, and to that app's redaction policy.

Model
-----
SurveyShield-iOS pins `OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1-mlx`.
MLX is Apple's on-device runtime format; it cannot execute on this Linux host.
The `-mlx` artifact is a re-packaging of the identical fine-tuned weights that
OpenMed also publishes as a standard transformers checkpoint:

    OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1   (DistilBERT, 106 labels)

Same weights, same tokenizer, same 106-label vocabulary -> same detections and
confidence scores. Only the execution backend differs (CPU/PyTorch here vs
Apple MLX on device), so these numbers reflect the real model's behavior.

Policy (from SurveyShield-iOS/SurveyShield/Models.swift -> buildDefault())
-------------------------------------------------------------------------
    auto_redact_threshold = 0.75
    review_threshold      = 0.55
    suppressed_labels     = {"time"}
    method_by_label       = mask for all identifying labels
"""
from __future__ import annotations

import json
import os
import sys
import time

import pandas as pd

# Make the surveyshield package importable from the sibling repo.
SURVEYSHIELD_SRC = os.environ.get(
    "SURVEYSHIELD_SRC",
    "/sessions/festive-focused-thompson/mnt/SurveyShield/src",
)
sys.path.insert(0, SURVEYSHIELD_SRC)

from surveyshield import (  # noqa: E402
    generate_synthetic_survey_export,
    evaluate_against_ground_truth,
)

MODEL_ID = "OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1"
MLX_MODEL_ID = "OpenMed/OpenMed-PII-LiteClinical-Small-66M-v1-mlx"

# --- iOS policy, transcribed from Models.swift -----------------------------
AUTO_REDACT_THRESHOLD = 0.75
REVIEW_THRESHOLD = 0.55
SUPPRESSED_LABELS = {"time"}
TEXT_COLUMNS = ["symptom_free_text", "additional_comments"]

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")


def build_pipeline():
    """Load the real OpenMed token-classification model on CPU."""
    from transformers import (
        AutoTokenizer,
        AutoModelForTokenClassification,
        pipeline,
    )

    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModelForTokenClassification.from_pretrained(MODEL_ID)
    # aggregation_strategy="first" merges sub-word tokens into whole-entity
    # spans and reports the score of the first token of each entity, which is
    # the convention OpenMed's own extract_pii uses.
    return pipeline(
        "token-classification",
        model=model,
        tokenizer=tok,
        aggregation_strategy="first",
        device=-1,
    )


def scan_with_real_model(df: pd.DataFrame, nlp) -> pd.DataFrame:
    """Scan open-text columns with the real model.

    Mirrors surveyshield.scan.scan_survey_for_pii's output contract but adds
    character offsets so span-level redaction can happen. confidence_threshold
    is effectively 0.0 -- every candidate the model emits reaches the policy
    layer, exactly as scan.py documents.
    """
    records = []
    for _, row in df.iterrows():
        for column in TEXT_COLUMNS:
            text = row[column]
            if not isinstance(text, str) or not text.strip():
                continue
            for ent in nlp(text):
                label = ent["entity_group"]
                start, end = int(ent["start"]), int(ent["end"])
                span = text[start:end]
                records.append(
                    {
                        "row_id": row["row_id"],
                        "column": column,
                        "entity_label": label,
                        "entity_text": span,
                        "confidence": float(ent["score"]),
                        "start": start,
                        "end": end,
                    }
                )
    return pd.DataFrame(
        records,
        columns=[
            "row_id",
            "column",
            "entity_label",
            "entity_text",
            "confidence",
            "start",
            "end",
        ],
    )


def route(scan_df: pd.DataFrame) -> dict:
    """Apply the iOS additional rules to the baseline OpenMed detections."""
    # 1. Drop suppressed labels (iOS: suppressedLabels, e.g. "time").
    suppressed = scan_df[scan_df["entity_label"].isin(SUPPRESSED_LABELS)]
    kept = scan_df[~scan_df["entity_label"].isin(SUPPRESSED_LABELS)]

    # 2. Drop noise below the review threshold.
    noise = kept[kept["confidence"] < REVIEW_THRESHOLD]
    considered = kept[kept["confidence"] >= REVIEW_THRESHOLD]

    # 3. Split the rest into auto-redact vs review tiers.
    auto = considered[considered["confidence"] >= AUTO_REDACT_THRESHOLD]
    review = considered[
        (considered["confidence"] >= REVIEW_THRESHOLD)
        & (considered["confidence"] < AUTO_REDACT_THRESHOLD)
    ]
    return {
        "suppressed": suppressed,
        "noise_below_review": noise,
        "auto_redact": auto,
        "review": review,
        "considered": considered,
    }


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    t0 = time.time()

    print("=" * 66)
    print("SurveyShield iOS-aligned evaluation - REAL OpenMed 66M model")
    print("=" * 66)
    print(f"Model (loaded):  {MODEL_ID}")
    print(f"Model (iOS pin): {MLX_MODEL_ID}  [same weights, MLX runtime]")
    print(f"Policy: auto>={AUTO_REDACT_THRESHOLD}  review>={REVIEW_THRESHOLD}  "
          f"suppressed={sorted(SUPPRESSED_LABELS)}")

    print("\n1. Generating synthetic export (300 rows, leak rate 0.12, seed 7)...")
    export = generate_synthetic_survey_export(n_rows=300, pii_leak_rate=0.12)
    print(f"   rows={len(export.survey_df)}  planted_entities={len(export.ground_truth)}")

    print("\n2. Loading real model on CPU (first run downloads ~260MB)...")
    nlp = build_pipeline()

    print("\n3. Scanning 300 rows x 2 open-text columns...")
    t_scan = time.time()
    scan_df = scan_with_real_model(export.survey_df, nlp)
    scan_secs = time.time() - t_scan
    print(f"   baseline detections={len(scan_df)}  scan_time={scan_secs:.1f}s")

    print("\n4. Applying iOS additional rules...")
    r = route(scan_df)
    print(f"   suppressed (time): {len(r['suppressed'])}")
    print(f"   dropped as noise (<{REVIEW_THRESHOLD}): {len(r['noise_below_review'])}")
    print(f"   auto-redact (>={AUTO_REDACT_THRESHOLD}): {len(r['auto_redact'])}")
    print(f"   held for review ({REVIEW_THRESHOLD}-{AUTO_REDACT_THRESHOLD}): {len(r['review'])}")

    # 5. Ground-truth grading.
    #    "additional rules" reflects the operational gate: an entity below the
    #    review threshold is discarded and a "time" entity is suppressed, so
    #    neither is credited as a detection. This is what the iOS app acts on.
    print("\n5. Grading against planted ground truth...")
    considered = r["considered"]
    eval_additional_rules = evaluate_against_ground_truth(considered, export.ground_truth)
    # "baseline OpenMed" ignores the policy and grades every candidate the model
    # emits, to separate model recall from the value of the additional rules.
    eval_baseline = evaluate_against_ground_truth(scan_df, export.ground_truth)

    print(f"   [additional rules]   P={eval_additional_rules['precision']:.1%}  "
          f"R={eval_additional_rules['recall']:.1%}  F1={eval_additional_rules['f1']:.3f}  "
          f"(TP={eval_additional_rules['true_positives']} "
          f"FP={eval_additional_rules['false_positives']} "
          f"FN={eval_additional_rules['false_negatives']})")
    print(f"   [baseline OpenMed]   P={eval_baseline['precision']:.1%}  "
          f"R={eval_baseline['recall']:.1%}  F1={eval_baseline['f1']:.3f}  "
          f"(TP={eval_baseline['true_positives']} "
          f"FP={eval_baseline['false_positives']} "
          f"FN={eval_baseline['false_negatives']})")

    # --- persist everything --------------------------------------------------
    scan_df.to_csv(os.path.join(OUT_DIR, "scan_detections.csv"), index=False)

    # per-label confidence summary (how the routing thresholds land on reality)
    conf_summary = (
        scan_df.groupby("entity_label")["confidence"]
        .agg(["count", "mean", "min", "max"])
        .sort_values("count", ascending=False)
        .round(4)
        .reset_index()
    )
    conf_summary.to_csv(os.path.join(OUT_DIR, "confidence_by_label.csv"), index=False)

    results = {
        "model_loaded": MODEL_ID,
        "model_ios_pin": MLX_MODEL_ID,
        "runtime_note": (
            "Real OpenMed 66M weights run on CPU/PyTorch. iOS ships the "
            "MLX-format packaging of the same weights; MLX is Apple-only and "
            "cannot run on this Linux host. Detections/scores are equivalent."
        ),
        "policy": {
            "auto_redact_threshold": AUTO_REDACT_THRESHOLD,
            "review_threshold": REVIEW_THRESHOLD,
            "suppressed_labels": sorted(SUPPRESSED_LABELS),
        },
        "dataset": {
            "rows": int(len(export.survey_df)),
            "text_columns": TEXT_COLUMNS,
            "planted_entities": int(len(export.ground_truth)),
            "seed": 7,
            "pii_leak_rate": 0.12,
        },
        "routing_counts": {
            "baseline_detections": int(len(scan_df)),
            "suppressed_time": int(len(r["suppressed"])),
            "dropped_as_noise": int(len(r["noise_below_review"])),
            "auto_redact": int(len(r["auto_redact"])),
            "held_for_review": int(len(r["review"])),
        },
        "evaluation_additional_rules": eval_additional_rules,
        "evaluation_baseline_openmed": eval_baseline,
        "scan_seconds": round(scan_secs, 2),
        "total_seconds": round(time.time() - t0, 2),
    }
    with open(os.path.join(OUT_DIR, "evaluation_results.json"), "w") as f:
        json.dump(results, f, indent=2, default=str)

    print(f"\nWrote results to {OUT_DIR}")
    print(f"Total time: {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
