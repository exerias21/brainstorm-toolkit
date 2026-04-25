#!/usr/bin/env python3
"""Feature eval runner — orchestrates pytest + fixture pipeline tests.

Discovers features by scanning <features_dir>/*/. Each feature directory may contain:
  - fixtures/     — input JSON files for pipeline layer
  - expected/     — expected output JSON (same filenames as fixtures/)
  - meta.json     — optional: {"script": "path", "script_input_flag": "--input",
                               "test_file": "tests/eval/test_X_eval.py"}

Pytest tests are discovered at <tests_dir>/test_{feature}_eval.py by default,
overridable via meta.json::test_file.

Outputs structured JSON results that can be fed to a fix agent.

Usage:
    python3 scripts/eval-runner.py --feature all --output json
    python3 scripts/eval-runner.py --feature my-feature --output text
    python3 scripts/eval-runner.py --features-dir evals/ --tests-dir tests/eval/
"""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def discover_features(features_dir: Path, tests_dir: Path) -> dict:
    """Scan features_dir for feature subdirectories. Build FEATURES dict."""
    features = {}
    if not features_dir.exists():
        return features

    for feature_path in sorted(features_dir.iterdir()):
        if not feature_path.is_dir():
            continue
        name = feature_path.name

        meta_file = feature_path / "meta.json"
        meta = json.loads(meta_file.read_text()) if meta_file.exists() else {}

        features[name] = {
            "test_file": meta.get("test_file", f"test_{name.replace('-', '_')}_eval.py"),
            "script": meta.get("script"),
            "script_input_flag": meta.get("script_input_flag", "--input"),
            "fixtures_dir": str(feature_path / "fixtures"),
            "expected_dir": str(feature_path / "expected"),
        }
    return features


def run_pytest_layer(feature_name: str, feature_config: dict, tests_dir: Path, project_root: Path) -> dict:
    """Run pytest tests for a feature."""
    test_file_path = feature_config["test_file"]
    if not Path(test_file_path).is_absolute():
        test_file = tests_dir / test_file_path
    else:
        test_file = Path(test_file_path)

    if not test_file.exists():
        return {"name": "classification-logic", "type": "pytest", "total": 0, "passed": 0, "failed": 0,
                "skipped": True, "reason": f"Test file not found: {test_file}", "failures": []}

    result = subprocess.run(
        [sys.executable, "-m", "pytest", str(test_file), "-v", "--tb=short", "-q"],
        capture_output=True, text=True, timeout=60, cwd=str(project_root),
    )

    output = result.stdout + result.stderr
    lines = output.strip().split("\n")

    total = 0
    passed = 0
    failed = 0
    failures = []

    for line in lines:
        if "passed" in line or "failed" in line:
            p = re.search(r"(\d+) passed", line)
            f = re.search(r"(\d+) failed", line)
            if p:
                passed = int(p.group(1))
            if f:
                failed = int(f.group(1))
            total = passed + failed

    if failed > 0:
        current_failure = {}
        for line in lines:
            if line.startswith("FAILED "):
                test_name = line.replace("FAILED ", "").strip()
                current_failure = {"test": test_name, "file": str(test_file)}
                failures.append(current_failure)
            elif "assert " in line and current_failure:
                current_failure["assertion"] = line.strip()

    return {
        "name": "classification-logic",
        "type": "pytest",
        "total": total,
        "passed": passed,
        "failed": failed,
        "failures": failures,
        "raw_output": output[-500:] if failed > 0 else None,
    }


def run_fixture_layer(feature_name: str, feature_config: dict, project_root: Path) -> dict:
    """Run pipeline simulation with fixtures."""
    if not feature_config.get("script") or not feature_config.get("script_input_flag"):
        return {"name": "pipeline-simulation", "type": "subprocess", "total": 0, "passed": 0, "failed": 0,
                "skipped": True, "reason": "No script or script_input_flag configured in meta.json"}

    fixtures_dir = Path(feature_config["fixtures_dir"])
    expected_dir = Path(feature_config["expected_dir"])

    if not fixtures_dir.exists():
        return {"name": "pipeline-simulation", "type": "subprocess", "total": 0, "passed": 0, "failed": 0,
                "skipped": True, "reason": f"Fixtures directory not found: {fixtures_dir}"}

    total = 0
    passed = 0
    failed = 0
    failures = []

    for fixture_file in sorted(fixtures_dir.glob("*.json")):
        expected_file = expected_dir / fixture_file.name
        if not expected_file.exists():
            continue

        total += 1

        script_path = project_root / feature_config["script"]
        try:
            result = subprocess.run(
                [sys.executable, str(script_path), feature_config["script_input_flag"],
                 str(fixture_file), "--output", "json"],
                capture_output=True, text=True, timeout=30, cwd=str(project_root),
            )
            actual_output = result.stdout.strip()
        except subprocess.TimeoutExpired:
            failed += 1
            failures.append({"fixture": fixture_file.name, "error": "Script timed out"})
            continue
        except Exception as e:
            failed += 1
            failures.append({"fixture": fixture_file.name, "error": str(e)})
            continue

        try:
            actual = json.loads(actual_output)
        except json.JSONDecodeError:
            failed += 1
            failures.append({"fixture": fixture_file.name, "error": "Invalid JSON output",
                             "raw_output": actual_output[:200]})
            continue

        expected = json.loads(expected_file.read_text())

        diffs = diff_json(expected, actual, path="")

        if diffs:
            failed += 1
            failures.append({"fixture": fixture_file.name, "diffs": diffs})
        else:
            passed += 1

    return {
        "name": "pipeline-simulation",
        "type": "subprocess",
        "total": total,
        "passed": passed,
        "failed": failed,
        "failures": failures,
    }


def diff_json(expected, actual, path: str = "", max_diffs: int = 20) -> list:
    """Generic recursive diff. Returns a list of human-readable diff strings."""
    diffs = []

    if type(expected) != type(actual):
        diffs.append(f"{path or 'root'}: type expected {type(expected).__name__}, got {type(actual).__name__}")
        return diffs

    if isinstance(expected, dict):
        for key in sorted(set(list(expected.keys()) + list(actual.keys()))):
            sub_path = f"{path}.{key}" if path else key
            if key not in expected:
                diffs.append(f"{sub_path}: unexpected (got {actual[key]!r})")
            elif key not in actual:
                diffs.append(f"{sub_path}: missing (expected {expected[key]!r})")
            else:
                diffs.extend(diff_json(expected[key], actual[key], sub_path, max_diffs))
            if len(diffs) >= max_diffs:
                return diffs
    elif isinstance(expected, list):
        if len(expected) != len(actual):
            diffs.append(f"{path or 'root'}: length expected {len(expected)}, got {len(actual)}")
            return diffs
        for i, (e, a) in enumerate(zip(expected, actual)):
            diffs.extend(diff_json(e, a, f"{path}[{i}]", max_diffs))
            if len(diffs) >= max_diffs:
                return diffs
    else:
        if expected != actual:
            diffs.append(f"{path or 'root'}: expected {expected!r}, got {actual!r}")

    return diffs


def run_feature_tests(feature_name: str, features: dict, tests_dir: Path, project_root: Path) -> dict:
    """Run all test layers for a feature."""
    if feature_name not in features:
        return {"feature": feature_name, "error": f"Unknown feature: {feature_name}",
                "available": sorted(features.keys())}

    config = features[feature_name]

    layer1 = run_pytest_layer(feature_name, config, tests_dir, project_root)
    layer2 = run_fixture_layer(feature_name, config, project_root)

    layers = [layer1, layer2]
    total = sum(l.get("total", 0) for l in layers)
    passed = sum(l.get("passed", 0) for l in layers)
    failed = sum(l.get("failed", 0) for l in layers)

    overall = "PASS" if failed == 0 and total > 0 else "FAIL" if failed > 0 else "SKIP"

    return {
        "feature": feature_name,
        "timestamp": datetime.now().isoformat(),
        "layers": layers,
        "total": total,
        "passed": passed,
        "failed": failed,
        "overall": overall,
        "summary": f"{passed}/{total} tests passed." + (f" {failed} failure(s)." if failed else ""),
    }


def run_all_tests(features: dict, tests_dir: Path, project_root: Path) -> dict:
    """Run tests for all discovered features."""
    results = []
    for name in features:
        results.append(run_feature_tests(name, features, tests_dir, project_root))

    total = sum(r.get("total", 0) for r in results)
    passed = sum(r.get("passed", 0) for r in results)
    failed = sum(r.get("failed", 0) for r in results)
    overall = "PASS" if failed == 0 and total > 0 else "FAIL" if failed > 0 else "SKIP"

    return {
        "timestamp": datetime.now().isoformat(),
        "features": results,
        "total": total,
        "passed": passed,
        "failed": failed,
        "overall": overall,
        "summary": f"{passed}/{total} tests passed across {len(results)} features.",
    }


def main():
    parser = argparse.ArgumentParser(description="Feature eval runner — pytest + fixture pipeline")
    parser.add_argument("--feature", default="all", help="Feature to test (or 'all'). Features are auto-discovered from --features-dir.")
    parser.add_argument("--features-dir", default="evals", help="Root directory where feature subdirectories live (default: evals)")
    parser.add_argument("--tests-dir", default="tests/eval", help="Directory where pytest test files live (default: tests/eval)")
    parser.add_argument("--output", default="json", choices=["json", "text"])
    args = parser.parse_args()

    project_root = Path.cwd()
    features_dir = project_root / args.features_dir
    tests_dir = project_root / args.tests_dir

    features = discover_features(features_dir, tests_dir)

    if not features:
        result = {
            "overall": "SKIP",
            "total": 0, "passed": 0, "failed": 0,
            "summary": f"No features discovered in {features_dir}. Create <features_dir>/<feature-name>/ subdirectories to register features.",
        }
    elif args.feature == "all":
        result = run_all_tests(features, tests_dir, project_root)
    else:
        result = run_feature_tests(args.feature, features, tests_dir, project_root)

    if args.output == "json":
        print(json.dumps(result, indent=2))
    else:
        print(f"\n{'=' * 55}")
        print(f"TEST RESULTS — {result.get('summary', 'No summary')}")
        print(f"{'=' * 55}")

        if "features" in result:
            for feat in result["features"]:
                status = "PASS" if feat["overall"] == "PASS" else "FAIL" if feat["overall"] == "FAIL" else "SKIP"
                print(f"\n  [{status}] {feat['feature']} — {feat.get('summary', '')}")
                for layer in feat.get("layers", []):
                    if layer.get("skipped"):
                        print(f"    {layer['name']}: skipped ({layer.get('reason', '')})")
                    else:
                        print(f"    {layer['name']}: {layer['passed']}/{layer['total']} passed")
                    for failure in layer.get("failures", []):
                        if "test" in failure:
                            print(f"      FAIL: {failure['test']}")
                        elif "fixture" in failure:
                            print(f"      FAIL: {failure['fixture']}")
                            for d in failure.get("diffs", []):
                                print(f"        {d}")
        else:
            for layer in result.get("layers", []):
                if layer.get("skipped"):
                    print(f"  {layer['name']}: skipped ({layer.get('reason', '')})")
                else:
                    print(f"  {layer['name']}: {layer['passed']}/{layer['total']} passed")

        print(f"\n{'=' * 55}")
        print(f"  Overall: {result.get('overall', 'UNKNOWN')}")

    sys.exit(0 if result.get("overall") in ("PASS", "SKIP") else 1)


if __name__ == "__main__":
    main()
