"""Validate the exchange JSON Schema against the example file and a set of
deliberately broken variants.  Run:  python datamodel/tests/validate_exchange_schema.py
Requires: pip install jsonschema  (>= 4.18)
"""
import copy
import json
import pathlib
import sys

from jsonschema import Draft202012Validator, FormatChecker

ROOT = pathlib.Path(__file__).resolve().parents[1]
schema = json.loads((ROOT / "json-schema" / "tree-exchange.schema.json").read_text(encoding="utf-8"))
example = json.loads((ROOT / "json-schema" / "examples" / "exchange-2026-10.example.json").read_text(encoding="utf-8"))

Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema, format_checker=FormatChecker())


def errors(doc):
    return sorted(e.message for e in validator.iter_errors(doc))


def mutate(fn):
    doc = copy.deepcopy(example)
    fn(doc)
    return doc


negative_cases = {
    "inspector name leaks (extra property)":
        lambda d: d["inspections"][0].update({"inspectorName": "Max Mustermann"}),
    "felled tree without felling block":
        lambda d: d["trees"][1].pop("felling"),
    "standing tree with felling block":
        lambda d: d["trees"][0].update({"felling": {"date": None, "reasonCode": None}}),
    "vitality out of range":
        lambda d: d["inspections"][0].update({"vitalityClass": 6}),
    "unknown defect severity":
        lambda d: d["inspections"][0]["defects"][0].update({"severity": "critical"}),
    "done measure without completion date":
        lambda d: d["measures"][1].update({"completedOn": None}),
    "open measure with completion date":
        lambda d: d["measures"][0].update({"completedOn": "2026-10-30"}),
    "wrong CRS":
        lambda d: d["header"].update({"crs": "EPSG:4326"}),
    "WGS84 coordinates in easting/northing":
        lambda d: d["trees"][0]["location"].update({"easting": 7.12, "northing": 50.73}),
    "missing plantingYear key (must be explicit null)":
        lambda d: d["trees"][1].pop("plantingYear"),
    "invalid date":
        lambda d: d["inspections"][0].update({"inspectionDate": "2026-13-45"}),
}

ok = True
errs = errors(example)
print(f"[{'PASS' if not errs else 'FAIL'}] example file is valid")
for e in errs:
    print("      ", e)
ok &= not errs

for name, fn in negative_cases.items():
    errs = errors(mutate(fn))
    passed = bool(errs)
    ok &= passed
    print(f"[{'PASS' if passed else 'FAIL'}] rejected: {name}" + (f"  -> {errs[0][:90]}" if errs else ""))

sys.exit(0 if ok else 1)
