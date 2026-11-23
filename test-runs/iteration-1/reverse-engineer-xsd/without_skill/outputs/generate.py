"""Generate JSON Schema and XSD artefacts from the canonical model.

Usage:
    python generate.py            # write generated/*
    python generate.py --check    # also validate the samples in samples/ against all schemas

Requires: PyYAML; --check additionally needs lxml and jsonschema.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape

import yaml

HERE = Path(__file__).resolve().parent
MODEL = HERE / "model" / "airquality.model.yaml"
OUT = HERE / "generated"

STRING_FACETS = {"minLength": "minLength", "maxLength": "maxLength", "pattern": "pattern"}
NUMBER_FACETS = {"minimum": "minInclusive", "maximum": "maxInclusive"}


def load_model() -> dict:
    return yaml.safe_load(MODEL.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------- helpers
def json_name(pname: str, prop: dict) -> str:
    return prop.get("json", {}).get("name", pname)


def xml_name(pname: str, prop: dict) -> str:
    return prop.get("xml", {}).get("name", pname)


def xsd_type_name(m: dict, tname: str) -> str:
    """Name of the XSD complex/simple type for a class or enum."""
    entry = m["classes"].get(tname) or m["enums"].get(tname)
    return entry.get("xml", {}).get("name", tname + "Type")


# --------------------------------------------------------------------------- JSON Schema
def json_prop_schema(m: dict, prop: dict) -> dict:
    t = prop["type"]
    if t in m["types"]:
        s = copy.deepcopy(m["types"][t]["json"])
        s.update(prop.get("constraints", {}))
    else:
        s = {"$ref": f"#/$defs/{t}"}
    if prop.get("description"):
        s["description"] = " ".join(prop["description"].split())
    if prop.get("nullable"):
        if "type" in s:
            s["type"] = [s["type"], "null"]
        else:
            s = {"anyOf": [s, {"type": "null"}]}
    if prop.get("many"):
        arr = {"type": "array", "items": s}
        if prop.get("required"):
            arr["minItems"] = 1
        return arr
    return s


def json_class(m: dict, cname: str) -> dict:
    cls = m["classes"][cname]
    props, req = {}, []
    for pname, prop in cls["properties"].items():
        jn = json_name(pname, prop)
        props[jn] = json_prop_schema(m, prop)
        if prop.get("required"):
            req.append(jn)
    out = {"type": "object"}
    if cls.get("description"):
        out["description"] = " ".join(cls["description"].split())
    out["properties"] = props
    out["required"] = req
    out["additionalProperties"] = False
    return out


def json_enum(m: dict, ename: str) -> dict:
    e = m["enums"][ename]
    base = m["types"][e["base"]]["json"]["type"]
    return {
        "type": base,
        "description": " ".join(e.get("description", "").split()),
        "enum": [v["value"] for v in e["values"]],
        "x-enumDescriptions": {str(v["value"]): v["description"] for v in e["values"]},
    }


def resolve_from(m: dict, ref: str) -> dict:
    cname, pname = ref.split(".")
    for key, prop in m["classes"][cname]["properties"].items():
        if key == pname:
            return prop
    raise KeyError(ref)


def json_view(m: dict, props_def: dict, description: str | None = None) -> dict:
    props, req = {}, []
    for pname, spec in props_def.items():
        if "from" in spec:
            s = json_prop_schema(m, resolve_from(m, spec["from"]))
        else:
            inner = json_view(m, spec["object"])
            s = {"type": "array", "items": inner, "minItems": 1} if spec.get("many") else inner
        props[pname] = s
        if spec.get("required"):
            req.append(pname)
    out = {"type": "object"}
    if description:
        out["description"] = " ".join(description.split())
    out.update({"properties": props, "required": req, "additionalProperties": False})
    return out


def build_json_schema(m: dict) -> dict:
    root = next(n for n, c in m["classes"].items() if c.get("root"))
    defs = {}
    for cname in m["classes"]:
        defs[cname] = json_class(m, cname)
    for ename in m["enums"]:
        defs[ename] = json_enum(m, ename)
    for vname, v in m.get("apiViews", {}).items():
        defs[vname] = json_view(m, v["properties"], v.get("description"))
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": m["model"]["json"]["id"],
        "title": f"{m['model']['name']} ({root})",
        "description": (
            f"GENERATED from model/airquality.model.yaml - do not edit by hand. "
            f"Canonical model version {m['model']['version']}, source: {m['model']['source']}. "
            f"The root validates a full delivery ({root}); API resources are available under $defs "
            f"(e.g. #/$defs/ObservationRecord, #/$defs/StationSummary)."
        ),
        "$ref": f"#/$defs/{root}",
        "$defs": defs,
    }


# --------------------------------------------------------------------------- XSD
def doc(text: str | None, indent: str) -> str:
    if not text:
        return ""
    t = escape(" ".join(text.split()))
    return f"{indent}<xs:annotation><xs:documentation>{t}</xs:documentation></xs:annotation>\n"


def xsd_simple_restriction(base: str, facets: dict, indent: str) -> str:
    lines = [f"{indent}<xs:simpleType>", f'{indent}  <xs:restriction base="{base}">']
    for k, v in facets.items():
        if k in STRING_FACETS:
            lines.append(f'{indent}    <xs:{STRING_FACETS[k]} value="{escape(str(v))}"/>')
        elif k in NUMBER_FACETS:
            lines.append(f'{indent}    <xs:{NUMBER_FACETS[k]} value="{v}"/>')
    lines += [f"{indent}  </xs:restriction>", f"{indent}</xs:simpleType>"]
    return "\n".join(lines) + "\n"


def xsd_type_ref(m: dict, prop: dict, strict: bool) -> tuple[str | None, str]:
    """Return (type attribute value or None, inline simpleType xml)."""
    t = prop["type"]
    if t in m["types"]:
        base = m["types"][t]["xsd"]
        facets = dict(prop.get("constraints", {})) if strict else {}
        if strict and t == "dateTime":
            return "aq:DateTimeWithOffset", ""
        if facets:
            return None, xsd_simple_restriction(base, facets, "        ")
        return base, ""
    if t in m["enums"]:
        e = m["enums"][t]
        if not strict and e.get("enforceInCompatXsd") is False:
            return m["types"][e["base"]]["xsd"], ""
        return f"{m['model']['xml']['prefix']}:{xsd_type_name(m, t)}", ""
    return f"{m['model']['xml']['prefix']}:{xsd_type_name(m, t)}", ""


def xsd_complex_body(m: dict, cname: str, strict: bool, indent: str) -> str:
    cls = m["classes"][cname]
    elems, attrs = [], []
    for pname, prop in cls["properties"].items():
        name = xml_name(pname, prop)
        tref, inline = xsd_type_ref(m, prop, strict)
        if prop.get("xml", {}).get("attribute"):
            use = ' use="required"' if prop.get("required") else ""
            attrs.append(f'{indent}  <xs:attribute name="{name}" type="{tref}"{use}/>')
            continue
        a = f'name="{name}"'
        if tref:
            a += f' type="{tref}"'
        if not prop.get("required"):
            a += ' minOccurs="0"'
        if prop.get("many"):
            a += ' maxOccurs="unbounded"'
        if prop.get("nullable"):
            a += ' nillable="true"'
        d = doc(prop.get("description"), indent + "      ")
        uniq = ""
        if strict:
            for u in prop.get("xsdStrictUnique", []):
                uniq += (f'{indent}      <xs:unique name="{u["name"]}">'
                         f'<xs:selector xpath="{u["selector"]}"/>'
                         + "".join(f'<xs:field xpath="{f}"/>' for f in u["fields"])
                         + "</xs:unique>\n")
        if d or inline or uniq:
            elems.append(f"{indent}    <xs:element {a}>\n{d}{inline}{uniq}{indent}    </xs:element>")
        else:
            elems.append(f"{indent}    <xs:element {a}/>")
    out = [f"{indent}  <xs:sequence>", *elems, f"{indent}  </xs:sequence>", *attrs]
    return "\n".join(out) + "\n"


def build_xsd(m: dict, strict: bool) -> str:
    x = m["model"]["xml"]
    root = next(n for n, c in m["classes"].items() if c.get("root"))
    mode = "STRICT (canonical constraints applied; proposal for 2.2)" if strict else \
        "COMPAT (accepts exactly what partner schema 2.1 accepts)"
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f"<!-- GENERATED from model/airquality.model.yaml - do not edit by hand. Mode: {mode}. -->",
        f'<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:{x["prefix"]}="{x["namespace"]}"',
        f'           targetNamespace="{x["namespace"]}" elementFormDefault="qualified" version="{x["schemaVersion"]}">',
    ]
    # root element: anonymous complex type, as in 2.1
    parts.append(f'  <xs:element name="{root}">')
    parts.append(doc(m["classes"][root].get("description"), "    ").rstrip("\n"))
    parts.append("    <xs:complexType>")
    parts.append(xsd_complex_body(m, root, strict, "    ").rstrip("\n"))
    parts.append("    </xs:complexType>")
    if strict:
        # identity constraint the 2.1 schema lacks (I-02)
        parts.append('    <xs:unique name="uniqueStationCode">')
        parts.append('      <xs:selector xpath="aq:station"/><xs:field xpath="aq:stationCode"/>')
        parts.append("    </xs:unique>")
    parts.append("  </xs:element>")
    for cname, cls in m["classes"].items():
        if cls.get("root"):
            continue
        parts.append(f'  <xs:complexType name="{xsd_type_name(m, cname)}">')
        d = doc(cls.get("description"), "    ")
        if d:
            parts.append(d.rstrip("\n"))
        parts.append(xsd_complex_body(m, cname, strict, "  ").rstrip("\n"))
        parts.append("  </xs:complexType>")
    for ename, e in m["enums"].items():
        if not strict and e.get("enforceInCompatXsd") is False:
            continue
        parts.append(f'  <xs:simpleType name="{xsd_type_name(m, ename)}">')
        parts.append(doc(e.get("description"), "    ").rstrip("\n"))
        parts.append(f'    <xs:restriction base="{m["types"][e["base"]]["xsd"]}">')
        for v in e["values"]:
            parts.append(f'      <xs:enumeration value="{v["value"]}">')
            parts.append(doc(v["description"], "        ").rstrip("\n"))
            parts.append("      </xs:enumeration>")
        parts.append("    </xs:restriction>")
        parts.append("  </xs:simpleType>")
    if strict:
        pat = m["types"]["dateTime"]["strictPattern"]
        parts.append('  <xs:simpleType name="DateTimeWithOffset">')
        parts.append(doc("xs:dateTime that must carry an explicit UTC offset (Z or +hh:mm/-hh:mm).", "    ").rstrip("\n"))
        parts.append(f'    <xs:restriction base="xs:dateTime"><xs:pattern value="{escape(pat)}"/></xs:restriction>')
        parts.append("  </xs:simpleType>")
    parts.append("</xs:schema>")
    return "\n".join(p for p in parts if p) + "\n"


# --------------------------------------------------------------------------- check
def xml_to_json(path: Path) -> dict:
    """Reference XML -> canonical JSON conversion (used for the round-trip check)."""
    from lxml import etree

    ns = {"aq": "http://example.org/airquality/2.1"}
    xsi_nil = "{http://www.w3.org/2001/XMLSchema-instance}nil"
    tree = etree.parse(str(path))

    def text(el, name):
        c = el.find(f"aq:{name}", ns)
        return None if c is None else c.text

    def num(el, name):
        c = el.find(f"aq:{name}", ns)
        if c is None or c.get(xsi_nil) in ("true", "1"):
            return None
        return float(c.text)

    stations = []
    for s in tree.getroot().findall("aq:station", ns):
        p = s.find("aq:position", ns)
        pos = {"lat": float(text(p, "lat")), "lon": float(text(p, "lon"))}
        if p.find("aq:altitude", ns) is not None:
            pos["altitude"] = num(p, "altitude")
        st = {"id": s.get("id"), "stationCode": text(s, "stationCode"), "name": text(s, "name")}
        if text(s, "operator") is not None:
            st["operator"] = text(s, "operator")
        st["position"] = pos
        st["stationType"] = text(s, "stationType")
        st["samplingPoints"] = []
        for sp in s.findall("aq:sampling", ns):
            obs = [{
                "begin": text(o, "begin"), "end": text(o, "end"), "value": num(o, "value"),
                "validity": int(text(o, "validity")), "verification": int(text(o, "verification")),
            } for o in sp.findall("aq:observation", ns)]
            st["samplingPoints"].append({"id": sp.get("id"), "pollutant": text(sp, "pollutant"),
                                         "unit": text(sp, "unit"), "observations": obs})
        stations.append(st)
    return {"stations": stations}


def check() -> int:
    from jsonschema import Draft202012Validator, FormatChecker
    from lxml import etree

    original = etree.XMLSchema(etree.parse(str(HERE / "observations.xsd")))
    compat = etree.XMLSchema(etree.parse(str(OUT / "observations.compat.xsd")))
    strict = etree.XMLSchema(etree.parse(str(OUT / "observations.strict.xsd")))
    schema = json.loads((OUT / "observations.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    jv = Draft202012Validator(schema, format_checker=FormatChecker())

    failures = 0
    print(f"{'sample':38} {'2.1 xsd':8} {'compat':8} {'strict':8} {'json':8}")
    for sample in sorted((HERE / "samples").glob("*.xml")):
        doc_ = etree.parse(str(sample))
        r = [original.validate(doc_), compat.validate(doc_), strict.validate(doc_)]
        try:
            data = xml_to_json(sample)
            errs = list(jv.iter_errors(data))
            r.append(not errs)
        except Exception as exc:  # conversion itself failed
            errs = [exc]
            r.append(False)
        expected = sample.stem.split("__")[-1]  # e.g. valid / compatonly
        print(f"{sample.name:38} " + " ".join(f"{str(v):8}" for v in r))
        if r[0] != r[1]:
            failures += 1
            print("   !! compat XSD disagrees with original 2.1 XSD")
        if expected == "valid" and not all(r):
            failures += 1
            for e in errs:
                print("   json:", getattr(e, "message", e))
            for log in (strict.error_log,):
                for e in log:
                    print("   strict:", e.message)
        if expected == "compatonly" and (r[2] or r[3] or not r[0]):
            failures += 1
            print("   !! expected: valid under 2.1/compat, rejected by strict + JSON")
    print("OK" if not failures else f"{failures} FAILURE(S)")
    return 1 if failures else 0


def main() -> int:
    m = load_model()
    OUT.mkdir(exist_ok=True)
    (OUT / "observations.schema.json").write_text(
        json.dumps(build_json_schema(m), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (OUT / "observations.compat.xsd").write_text(build_xsd(m, strict=False), encoding="utf-8")
    (OUT / "observations.strict.xsd").write_text(build_xsd(m, strict=True), encoding="utf-8")
    print("wrote", ", ".join(p.name for p in sorted(OUT.iterdir())))
    if "--check" in sys.argv:
        return check()
    return 0


if __name__ == "__main__":
    sys.exit(main())
