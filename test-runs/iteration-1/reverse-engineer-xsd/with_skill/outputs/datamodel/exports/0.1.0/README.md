# Exports 0.1.0 (generated — do not edit)

| File | What | How generated |
|------|------|---------------|
| `airquality.schema.json` | JSON Schema 2020-12, root = ObservationCollection | `dmtool.py export model.yaml --format jsonschema` |
| `airquality.xsd` | Model-native XSD (identifiers as elements) — **not** wire-compatible with 2.1 | `dmtool.py export model.yaml --format xsd` |
| `airquality-2.1-compat.xsd` | Partner wire format 2.1 | `python -I tools/xsd_compat_2_1.py airquality.xsd airquality-2.1-compat.xsd` (D-005) |
| `model.mmd` | Mermaid class diagram | `dmtool.py diagram` |
| `examples/delivery.xml`, `examples/delivery.json` | The same sample delivery in both formats | hand-written, fictitious values |

Checks run 2026-11-23 (lxml, jsonschema): `delivery.xml` is valid against the original S1 XSD and against `airquality-2.1-compat.xsd`; `delivery.json` is valid against the JSON Schema (the schema itself passes the 2020-12 meta-schema); a negative test (unknown validity code, extra property) is rejected. `format: date-time` was not checked (no RFC 3339 validator installed). Cross-field constraints C-001..C-007 are documentation only (`$comment` / `xs:documentation`).
