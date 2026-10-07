"""Run the four normal-damage chapter diagnostics against one source snapshot.

This is evidence for a specified controller policy, not a human balance verdict.
The Godot test owns unique OS-temp save/preference isolation. Runs are sequential
to avoid comparing games competing for CPU. Every output directory is exclusive.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import time

PROJECT = Path(__file__).resolve().parents[1]
CAREERS = ("warrior", "rogue", "barbarian", "mage")
HARNESS_FILES = ("tests/chapter_playthrough.gd", "tests/frontend_rpg.gd", "tools/chapter_balance.py", "tools/export/build.py")
spec = importlib.util.spec_from_file_location("mosslight_export_helpers", PROJECT / "tools/export/build.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def snapshot():
    result = exporter.source_manifest()
    for relative in HARNESS_FILES:
        result[relative] = exporter.digest(PROJECT / relative)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--career", action="append", choices=CAREERS)
    parser.add_argument("--seed", type=int, default=930)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    baseline = snapshot()
    exporter.write_new(output / "source-manifest.json", baseline)
    report = {"ok": False, "scope": "Continuous chapter with actual inputs, NPC dialogue, normal damage, finite resources and disk reconstruction; automated policy, not a human playtest.",
              "engine": str(engine), "engine_sha256": exporter.digest(engine), "seed": args.seed,
              "cases": [], "source_changed": [], "started_unix": time.time()}
    try:
        for relative in HARNESS_FILES:
            target = output / "harness" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as archived:
                archived.write((PROJECT / relative).read_bytes())
            if exporter.digest(target) != baseline[relative]:
                raise RuntimeError("Harness changed while archiving: " + relative)
        for career in args.career or CAREERS:
            case_path = output / career
            case_path.mkdir(exist_ok=False)
            evidence = case_path / "evidence"
            argv = [str(engine), "--headless", "--fixed-fps", "60", "--path", str(PROJECT),
                    "--log-file", str(case_path / "engine.log"), "--script", "res://tests/chapter_playthrough.gd", "--",
                    "--career=" + career, "--seed=" + str(args.seed), "--evidence=" + evidence.as_posix()]
            print("START " + career, flush=True)
            execution = exporter.run(argv, PROJECT, case_path, "run", args.timeout)
            errors = exporter.errors_in(case_path, "run")
            diagnostics = []
            for name in ("run.stdout.log", "run.stderr.log"):
                diagnostics += [line for line in (case_path / name).read_text("utf-8", errors="replace").splitlines()
                                if "WARNING:" in line]
            outcome_path = evidence / "report.json"
            outcome = json.loads(outcome_path.read_text("utf-8")) if outcome_path.exists() else {}
            changed = snapshot()
            drift = sorted(path for path in set(baseline) | set(changed) if baseline.get(path) != changed.get(path))
            case = {"career": career, "execution": execution, "report": outcome, "errors": errors, "warnings": diagnostics,
                    "source_changed": drift, "report_path": str(outcome_path)}
            report["cases"].append(case)
            print(json.dumps({"career": career, "returncode": execution["returncode"], "errors": errors,
                              "source_changed": drift, "report": str(outcome_path)}, ensure_ascii=False), flush=True)
            if drift:
                report["source_changed"] = drift
                break
        # A failure is kept as gameplay evidence; never recast a partial run as
        # a balanced game. Caller inspects per-stage trace before changing data.
        report["ok"] = bool(report["cases"]) and not report["source_changed"] and all(
            case["execution"]["returncode"] == 0 and not case["errors"] and case["report"].get("ok") is True
            for case in report["cases"])
    except Exception as error:
        report["runner_error"] = repr(error)
    finally:
        report["finished_unix"] = time.time()
        exporter.write_new(output / "report.json", report)
        print("MATRIX_REPORT " + str(output / "report.json"), flush=True)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
