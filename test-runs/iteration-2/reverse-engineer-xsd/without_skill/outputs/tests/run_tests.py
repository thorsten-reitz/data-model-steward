"""Checks that the model-generated artefacts behave as intended.

1. Generated XSD accepts/rejects exactly what the partner XSD 2.1 does
   (on the sample and a set of mutations).
2. XML -> JSON conversion of every 2.1-valid case is checked against the
   JSON Schema; the expected result documents where the API is deliberately
   stricter than 2.1 (see xsd-review.md).
3. XML -> JSON -> XML round trip is lossless (value-equal) and still valid.

    python tests/run_tests.py
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import jsonschema
from lxml import etree

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from convert import json2xml, xml2json  # noqa: E402
from model import Model  # noqa: E402

subprocess.run([sys.executable, str(ROOT / "tools" / "generate.py")], check=True, capture_output=True)

ORIGINAL = etree.XMLSchema(etree.parse(str(ROOT / "observations.xsd")))
GENERATED = etree.XMLSchema(etree.parse(str(ROOT / "generated" / "observations.xsd")))
SCHEMA = json.loads((ROOT / "generated" / "airquality.schema.json").read_text(encoding="utf-8"))
jsonschema.Draft202012Validator.check_schema(SCHEMA)
VALIDATOR = jsonschema.Draft202012Validator(SCHEMA, format_checker=jsonschema.FormatChecker())
MODEL = Model()
SAMPLE = (ROOT / "examples" / "sample.xml").read_text(encoding="utf-8")

FIRST_OBS_BEGIN = "<aq:begin>2026-11-22T00:00:00+01:00</aq:begin>"

# (name, old, new, expect XSD 2.1 valid, expect JSON valid [None = n/a], issue)
CASES = [
    ("baseline sample", None, None, True, True, ""),
    ("missing stationCode", "<aq:stationCode>DEBE065</aq:stationCode>", "", False, None, ""),
    ("unknown element", "<aq:name>Potsdam-Zentrum</aq:name>",
     "<aq:name>Potsdam-Zentrum</aq:name><aq:foo/>", False, None, ""),
    ("station without sampling point",
     None, None, False, None, ""),  # handled specially below
    ("stationType outside enum", "<aq:stationType>background</aq:stationType>",
     "<aq:stationType>urban</aq:stationType>", False, None, "Q10"),
    ("sampling id == station id (shared xs:ID space)", 'id="SP_DEBB021_O3"', 'id="ST_DEBE065"',
     False, None, "Q2"),
    ("id starting with a digit", 'id="ST_DEBB021"', 'id="12345"', False, None, "Q2"),
    ("value nil", None, None, True, True, ""),  # covered by baseline
    # --- 2.1-valid but questionable: tightened in the JSON Schema -------------
    ("validity code 7 (not in EEA list)", "<aq:validity>1</aq:validity>",
     "<aq:validity>7</aq:validity>", True, False, "Q6"),
    ("verification code 0", "<aq:verification>3</aq:verification>",
     "<aq:verification>0</aq:verification>", True, False, "Q6"),
    ("latitude 123", "<aq:lat>52.398</aq:lat>", "<aq:lat>123</aq:lat>", True, False, "Q3"),
    ("begin without UTC offset", FIRST_OBS_BEGIN,
     "<aq:begin>2026-11-22T00:00:00</aq:begin>", True, False, "Q3b"),
    ("empty pollutant", "<aq:pollutant>O3</aq:pollutant>", "<aq:pollutant></aq:pollutant>",
     True, False, "Q5"),
    ("value INF", "<aq:value>18.0</aq:value>", "<aq:value>INF</aq:value>", True, False, "Q15"),
    # --- 2.1-valid and NOT caught by either schema (needs business rules) -----
    ("end before begin", "<aq:end>2026-11-22T01:00:00+01:00</aq:end>",
     "<aq:end>2026-11-21T01:00:00+01:00</aq:end>", True, True, "Q9"),
    ("nil value flagged valid", "<aq:validity>-99</aq:validity>", "<aq:validity>1</aq:validity>",
     True, True, "Q7"),
    ("two sampling points for same pollutant", "<aq:pollutant>PM10</aq:pollutant>",
     "<aq:pollutant>NO2</aq:pollutant>", True, True, "Q8"),
]


def mutate(old, new, name):
    if name == "station without sampling point":
        start = SAMPLE.index('<aq:sampling id="SP_DEBB021_O3">')
        end = SAMPLE.index("</aq:sampling>", start) + len("</aq:sampling>")
        return SAMPLE[:start] + SAMPLE[end:]
    if old is None:
        return SAMPLE
    assert old in SAMPLE, f"{name}: pattern not found"
    return SAMPLE.replace(old, new, 1)


def normalised(path):
    """XSD tree without annotations/comments/whitespace, top-level children sorted."""
    tree = etree.parse(str(path), etree.XMLParser(remove_blank_text=True, remove_comments=True))
    root = tree.getroot()
    for ann in root.iter("{http://www.w3.org/2001/XMLSchema}annotation"):
        ann.getparent().remove(ann)
    kids = sorted(root, key=lambda e: (e.tag, e.get("name", "")))
    for k in list(root):
        root.remove(k)
    root.extend(kids)
    return etree.tostring(root, method="c14n")


failures = 0
structurally_equal = normalised(ROOT / "observations.xsd") == normalised(ROOT / "generated" / "observations.xsd")
print("generated XSD structurally identical to partner 2.1 (ignoring docs/order of global types):",
      structurally_equal)
failures += not structurally_equal
print(f"{'case':55} {'2.1':>5} {'gen':>5} {'json':>5}  issue")
for name, old, new, exp_xsd, exp_json, issue in CASES:
    doc = etree.fromstring(mutate(old, new, name).encode("utf-8"))
    orig_ok, gen_ok = ORIGINAL.validate(doc), GENERATED.validate(doc)
    json_ok = None
    if orig_ok:
        try:
            obj = xml2json(MODEL, etree.tostring(doc))
            json_ok = VALIDATOR.is_valid(obj)
            if json_ok:  # round trip
                back = etree.fromstring(json2xml(MODEL, obj))
                assert ORIGINAL.validate(back), ORIGINAL.error_log
                assert xml2json(MODEL, etree.tostring(back)) == obj, "round trip changed data"
        except ValueError:
            json_ok = False
    ok = orig_ok == gen_ok == exp_xsd and json_ok == exp_json
    failures += not ok
    fmt = lambda b: "-" if b is None else ("ok" if b else "rej")  # noqa: E731
    print(f"{name:55} {fmt(orig_ok):>5} {fmt(gen_ok):>5} {fmt(json_ok):>5}  {issue}"
          + ("" if ok else "   <-- UNEXPECTED"))

# Write the converted sample for reference.
(ROOT / "examples" / "sample.json").write_text(
    json.dumps(xml2json(MODEL, SAMPLE.encode("utf-8")), indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8")

print("\nFAILED" if failures else "\nall cases behaved as expected")
sys.exit(1 if failures else 0)
