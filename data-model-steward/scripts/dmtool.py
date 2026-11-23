#!/usr/bin/env python3
"""dmtool — validate, diagram, export and diff canonical data models (model.yaml).

Usage:
  dmtool.py validate <model.yaml>
  dmtool.py diagram  <model.yaml> [-o out.mmd]
  dmtool.py export   <model.yaml> --format jsonschema|xsd|postgres [-o out]
  dmtool.py diff     <old.yaml> <new.yaml> [--json]

Requires PyYAML. Format: references/model-format.md
"""
import argparse
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("dmtool needs PyYAML: pip install pyyaml")

PRIMITIVES = {"string", "text", "boolean", "integer", "long", "decimal", "float", "date",
              "dateTime", "time", "duration", "uri", "uuid", "binary", "geometry"}
MULT_RE = re.compile(r"^(\d+)(?:\.\.(\d+|\*))?$|^\*$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
UPPER_CAMEL = re.compile(r"^[A-Z][A-Za-z0-9]*$")
LOWER_CAMEL = re.compile(r"^[a-z][A-Za-z0-9]*$")
INF = float("inf")


# --------------------------------------------------------------------------- model access

def load(path):
    with open(path, encoding="utf-8") as f:
        m = yaml.safe_load(f) or {}
    m.setdefault("model", {})
    for key in ("classes", "datatypes", "enumerations"):
        m[key] = m.get(key) or {}
    m["associations"] = m.get("associations") or []
    m["constraints"] = m.get("constraints") or []
    return m


def mult(s):
    """'0..*' -> (0, inf). Returns None when malformed."""
    s = "1" if s is None else str(s).strip()
    if s == "*":
        return (0, INF)
    mm = MULT_RE.match(s)
    if not mm:
        return None
    lo = int(mm.group(1))
    hi = mm.group(2)
    if hi is None:
        return (lo, lo)
    return (lo, INF if hi == "*" else int(hi))


def mult_str(lo, hi):
    return f"{lo}..{'*' if hi == INF else hi}" if lo != hi else str(lo)


def attrs_of(elem):
    return elem.get("attributes") or {}


def all_attrs(m, cname):
    """Attributes including inherited ones, parent first."""
    chain, seen, c = [], set(), cname
    while c and c in m["classes"] and c not in seen:
        seen.add(c)
        chain.append(c)
        c = m["classes"][c].get("extends")
    out = {}
    for c in reversed(chain):
        out.update(attrs_of(m["classes"][c]))
    return out


def identifier(m, cname):
    c, seen = cname, set()
    while c and c in m["classes"] and c not in seen:
        seen.add(c)
        ident = m["classes"][c].get("identifier")
        if ident and ident.get("attribute"):
            return ident
        c = m["classes"][c].get("extends")
    return None


def root_class(m, cname):
    c, seen = cname, set()
    while m["classes"].get(c, {}).get("extends") and c not in seen:
        seen.add(c)
        c = m["classes"][c]["extends"]
    return c


def snake(name):
    s = re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
    return s.lower()


def is_part(m, cname):
    return any(a.get("kind") == "composition" and a["to"]["class"] == cname for a in m["associations"])


# --------------------------------------------------------------------------- validate

def validate(m, model_path=None):
    errors, warnings, info = [], [], []
    hdr = m["model"]
    for k in ("name", "version", "namespace"):
        if not hdr.get(k):
            errors.append(f"model.{k} is missing")
    if hdr.get("version") and not SEMVER_RE.match(str(hdr["version"])):
        errors.append(f"model.version '{hdr['version']}' is not semantic (x.y.z)")
    if hdr.get("status") not in (None, "draft", "released"):
        errors.append("model.status must be draft or released")

    names = {}
    for kind in ("classes", "datatypes", "enumerations"):
        for n in m[kind]:
            if n in names:
                errors.append(f"'{n}' defined as both {names[n]} and {kind}")
            names[n] = kind
            if n in PRIMITIVES:
                errors.append(f"'{n}' shadows a primitive type")
            if not UPPER_CAMEL.match(n):
                warnings.append(f"{kind[:-1] if kind != 'classes' else 'class'} '{n}' is not UpperCamelCase")

    proposed = []

    def check_common(path, e):
        if not isinstance(e, dict):
            errors.append(f"{path}: expected a mapping")
            return False
        if not e.get("description"):
            warnings.append(f"{path}: no description")
        if e.get("status") == "proposed":
            proposed.append(path)
        dep = e.get("deprecated")
        if dep is not None and not isinstance(dep, (dict, bool)):
            errors.append(f"{path}: deprecated must be a mapping {{since, reason, replacedBy}}")
        return True

    def check_attr(path, a, owner_kind):
        if not isinstance(a, dict):
            errors.append(f"{path}: expected a mapping")
            return
        if not a.get("description"):
            info.append(f"{path}: no description")
        if a.get("status") == "proposed":
            proposed.append(path)
        t = a.get("type")
        if not t:
            errors.append(f"{path}: type missing")
        elif t in m["classes"]:
            errors.append(f"{path}: type '{t}' is a class — use an association instead")
        elif t not in PRIMITIVES and t not in m["datatypes"] and t not in m["enumerations"]:
            errors.append(f"{path}: unknown type '{t}'")
        if mult(a.get("multiplicity")) is None:
            errors.append(f"{path}: bad multiplicity '{a.get('multiplicity')}'")
        else:
            lo, hi = mult(a.get("multiplicity"))
            if lo > hi:
                errors.append(f"{path}: lower bound > upper bound")
        if not LOWER_CAMEL.match(path.split(".")[-1]):
            warnings.append(f"{path}: attribute name not lowerCamelCase")
        if t == "geometry":
            c = a.get("constraints") or {}
            if not c.get("crs"):
                warnings.append(f"{path}: geometry without crs")

    for n, e in m["enumerations"].items():
        if not check_common(n, e):
            continue
        vals = e.get("values") or []
        if not vals and not e.get("extensible"):
            errors.append(f"{n}: closed enumeration without values")
        codes = [v.get("code") if isinstance(v, dict) else v for v in vals]
        dup = {c for c in codes if codes.count(c) > 1}
        if dup:
            errors.append(f"{n}: duplicate codes {sorted(dup)}")

    for n, e in m["datatypes"].items():
        if check_common(n, e):
            for an, a in attrs_of(e).items():
                check_attr(f"{n}.{an}", a, "datatype")

    for n, e in m["classes"].items():
        if not check_common(n, e):
            continue
        p = e.get("extends")
        if p and p not in m["classes"]:
            errors.append(f"{n}: extends unknown class '{p}'")
        # cycle check
        seen, c = set(), n
        while c in m["classes"] and m["classes"][c].get("extends"):
            if c in seen:
                errors.append(f"{n}: inheritance cycle")
                break
            seen.add(c)
            c = m["classes"][c]["extends"]
        for an, a in attrs_of(e).items():
            check_attr(f"{n}.{an}", a, "class")
            if p and an in all_attrs(m, p):
                errors.append(f"{n}.{an}: redefines inherited attribute")
        ident = e.get("identifier")
        if ident:
            ia = ident.get("attribute")
            if ia and ia not in all_attrs(m, n):
                errors.append(f"{n}: identifier attribute '{ia}' not found")
            elif ia:
                lo, hi = mult(all_attrs(m, n)[ia].get("multiplicity")) or (1, 1)
                if (lo, hi) != (1, 1):
                    errors.append(f"{n}: identifier '{ia}' must have multiplicity 1")
            if ident.get("strategy") not in (None, "uuid", "natural", "sequence", "uri"):
                errors.append(f"{n}: unknown identifier strategy '{ident.get('strategy')}'")
        elif not p and not is_part(m, n):
            warnings.append(f"{n}: no identifier defined (a surrogate key will be generated)")
        hist = e.get("history") or {}
        if hist.get("mode") not in (None, "none", "audit", "versioned", "bitemporal"):
            errors.append(f"{n}: unknown history.mode '{hist.get('mode')}'")
        if "history" not in e and not p and not is_part(m, n):
            info.append(f"{n}: history requirements not recorded yet")
        if "nfr" not in e and not p and not is_part(m, n):
            info.append(f"{n}: non-functional requirements (volume etc.) not recorded yet")

    roles = {}
    assoc_names = set()
    for i, a in enumerate(m["associations"]):
        label = a.get("name") or f"associations[{i}]"
        if a.get("name") in assoc_names:
            errors.append(f"{label}: duplicate association name")
        assoc_names.add(a.get("name"))
        if not a.get("name"):
            warnings.append(f"{label}: unnamed association")
        if a.get("status") == "proposed":
            proposed.append(label)
        if a.get("kind", "reference") not in ("reference", "aggregation", "composition"):
            errors.append(f"{label}: unknown kind '{a.get('kind')}'")
        for end_name in ("from", "to"):
            end = a.get(end_name)
            if not isinstance(end, dict) or not end.get("class"):
                errors.append(f"{label}: '{end_name}' end missing class")
                continue
            if end["class"] not in m["classes"]:
                errors.append(f"{label}: {end_name} class '{end['class']}' unknown")
            if mult(end.get("multiplicity")) is None:
                errors.append(f"{label}: bad {end_name} multiplicity '{end.get('multiplicity')}'")
            if not end.get("role"):
                warnings.append(f"{label}: {end_name} end has no role name")
        if isinstance(a.get("from"), dict) and isinstance(a.get("to"), dict):
            # role on `to` is a property of `from` class, and vice versa
            for owner, end in ((a["from"].get("class"), a["to"]), (a["to"].get("class"), a["from"])):
                r = end.get("role")
                if not r or owner not in m["classes"]:
                    continue
                if r in all_attrs(m, owner):
                    errors.append(f"{label}: role '{r}' clashes with attribute {owner}.{r}")
                if (owner, r) in roles:
                    errors.append(f"{label}: role '{owner}.{r}' already used by {roles[(owner, r)]}")
                roles[(owner, r)] = label
            if a.get("kind") == "composition":
                fm = mult(a["from"].get("multiplicity"))
                if fm and fm[1] > 1:
                    errors.append(f"{label}: composition whole ('from') must have upper bound 1")

    owners = {}
    for a in m["associations"]:
        if a.get("kind") == "composition" and isinstance(a.get("to"), dict):
            owners.setdefault(a["to"].get("class"), []).append(a.get("name"))
    for part, lst in owners.items():
        if len(lst) > 1:
            warnings.append(f"{part}: part of several compositions {lst} — check exclusivity")

    for c in m["constraints"]:
        if not c.get("id"):
            warnings.append("constraint without id")
        if c.get("appliesTo") and c["appliesTo"] not in names:
            errors.append(f"constraint {c.get('id')}: appliesTo unknown '{c['appliesTo']}'")

    # source references against sources.md, if present next to the model
    if model_path:
        sfile = Path(model_path).parent / "sources.md"
        if sfile.exists():
            known = set(re.findall(r"\bS\d+\b", sfile.read_text(encoding="utf-8")))
            used = set(re.findall(r"\bS\d+\b", yaml.safe_dump(_collect_sources(m))))
            missing = sorted(used - known)
            if missing:
                warnings.append(f"sources referenced but not in sources.md: {missing}")

    if proposed:
        (errors if hdr.get("status") == "released" else warnings).append(
            f"elements still 'proposed': {proposed}")
    return errors, warnings, info


def _collect_sources(obj):
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "sources":
                out.extend(v if isinstance(v, list) else [v])
            else:
                out.extend(_collect_sources(v))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(_collect_sources(v))
    return [str(s) for s in out]


# --------------------------------------------------------------------------- diagram

def diagram(m):
    L = ["classDiagram"]
    for n, e in m["enumerations"].items():
        L.append(f"  class {n} {{\n    <<enumeration>>")
        for v in e.get("values") or []:
            L.append(f"    {v.get('code') if isinstance(v, dict) else v}")
        L.append("  }")
    for kind, stereo in (("datatypes", "datatype"), ("classes", None)):
        for n, e in m[kind].items():
            L.append(f"  class {n} {{")
            if stereo:
                L.append(f"    <<{stereo}>>")
            elif e.get("abstract"):
                L.append("    <<abstract>>")
            for an, a in attrs_of(e).items():
                ms = a.get("multiplicity", "1")
                suffix = "" if str(ms) == "1" else f" [{ms}]"
                L.append(f"    +{a.get('type')} {an}{suffix}")
            L.append("  }")
    for n, e in m["classes"].items():
        if e.get("extends"):
            L.append(f"  {e['extends']} <|-- {n}")
    for a in m["associations"]:
        f, t = a["from"], a["to"]
        arrow = {"composition": "*--", "aggregation": "o--"}.get(a.get("kind"), "-->")
        L.append(f'  {f["class"]} "{f.get("multiplicity", "1")}" {arrow} "{t.get("multiplicity", "1")}" '
                 f'{t["class"]} : {t.get("role") or a.get("name", "")}')
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------- JSON Schema

JSON_TYPES = {
    "string": {"type": "string"}, "text": {"type": "string"}, "boolean": {"type": "boolean"},
    "integer": {"type": "integer"}, "long": {"type": "integer"}, "decimal": {"type": "number"},
    "float": {"type": "number"}, "date": {"type": "string", "format": "date"},
    "dateTime": {"type": "string", "format": "date-time"}, "time": {"type": "string", "format": "time"},
    "duration": {"type": "string", "format": "duration"}, "uri": {"type": "string", "format": "uri"},
    "uuid": {"type": "string", "format": "uuid"},
    "binary": {"type": "string", "contentEncoding": "base64"},
    "geometry": {"$ref": "https://geojson.org/schema/Geometry.json"},
}


def _json_value_schema(m, a):
    t = a["type"]
    if t in m["enumerations"] or t in m["datatypes"]:
        s = {"$ref": f"#/$defs/{t}"}
    else:
        s = dict(JSON_TYPES[t])
        c = a.get("constraints") or {}
        for src, dst in (("maxLength", "maxLength"), ("minLength", "minLength"), ("pattern", "pattern"),
                         ("min", "minimum"), ("max", "maximum")):
            if src in c and t not in ("geometry",):
                s[dst] = c[src]
        if t == "geometry" and c.get("geometryType") and c["geometryType"] != "Geometry":
            s = {"$ref": f"https://geojson.org/schema/{c['geometryType']}.json"}
        if c.get("unit"):
            s["$comment"] = f"unit: {c['unit']}"
    return s


def _json_property(m, a, desc=True):
    lo, hi = mult(a.get("multiplicity"))
    s = _json_value_schema(m, a)
    if a.get("voidable"):
        s = {"anyOf": [s, {"type": "null"}]}
    if hi > 1:
        s = {"type": "array", "items": s}
        if lo:
            s["minItems"] = lo
        if hi != INF:
            s["maxItems"] = hi
    if desc and a.get("description"):
        s = {"description": a["description"], **s} if "$ref" not in s else {"description": a["description"], "allOf": [s]}
    if a.get("deprecated"):
        s["deprecated"] = True
    return s, lo >= 1


def _ref_schema(m, target):
    ident = identifier(m, target)
    if ident:
        a = all_attrs(m, target)[ident["attribute"]]
        s = _json_value_schema(m, a)
    else:
        s = {"type": "string"}
    return {"description": f"Reference to {target} by identifier", **s} if "$ref" not in s else s


def export_jsonschema(m):
    hdr = m["model"]
    opts = (hdr.get("exportOptions") or {}).get("jsonschema") or {}
    closed = opts.get("closed", True)
    defs = {}
    for n, e in m["enumerations"].items():
        codes = [v.get("code") if isinstance(v, dict) else v for v in e.get("values") or []]
        if e.get("extensible"):
            defs[n] = {"description": e.get("description", ""),
                       "type": "string", "examples": codes,
                       "$comment": "extensible code list; known values in examples"}
        else:
            defs[n] = {"description": e.get("description", ""), "enum": codes}
    for n, e in m["datatypes"].items():
        props, req = {}, []
        for an, a in attrs_of(e).items():
            props[an], r = _json_property(m, a)
            if r and not a.get("voidable"):
                req.append(an)
        d = {"description": e.get("description", ""), "type": "object", "properties": props}
        if req:
            d["required"] = req
        if closed:
            d["additionalProperties"] = False
        defs[n] = d
    for n, e in m["classes"].items():
        props, req = {}, []
        for an, a in attrs_of(e).items():
            if a.get("derived"):
                props[an], _ = _json_property(m, a)
                props[an]["readOnly"] = True
                continue
            props[an], r = _json_property(m, a)
            if r and not a.get("voidable"):
                req.append(an)
        for a in m["associations"]:
            for owner_end, other_end, forward in (("from", "to", True), ("to", "from", False)):
                if a[owner_end]["class"] != n:
                    continue
                if not forward and a.get("navigable", "from") != "both":
                    continue
                if not forward and a.get("kind") == "composition":
                    continue  # parts are nested, no back pointer
                role = a[other_end].get("role")
                if not role:
                    continue
                target = a[other_end]["class"]
                lo, hi = mult(a[other_end].get("multiplicity"))
                item = {"$ref": f"#/$defs/{target}"} if (a.get("kind") == "composition" and forward) \
                    else _ref_schema(m, target)
                s = item if hi == 1 else {"type": "array", "items": item,
                                          **({"minItems": lo} if lo else {}),
                                          **({"maxItems": hi} if hi != INF else {})}
                if a.get("description") and "$ref" not in s:
                    s = {"description": a["description"], **s}
                props[role] = s
                if lo >= 1:
                    req.append(role)
        hist = (e.get("history") or {})
        if hist.get("mode") in ("versioned", "bitemporal") and not e.get("extends"):
            props["versionId"] = {"type": "string", "description": "Version of this object"}
            if hist.get("validTime", True):
                props["validFrom"] = {"type": "string", "format": "date-time"}
                props["validTo"] = {"anyOf": [{"type": "string", "format": "date-time"}, {"type": "null"}]}
            if hist.get("mode") == "bitemporal" or hist.get("transactionTime"):
                props["recordedAt"] = {"type": "string", "format": "date-time"}
        d = {"description": e.get("description", ""), "type": "object", "properties": props}
        if req:
            d["required"] = req
        if e.get("extends"):
            d = {"allOf": [{"$ref": f"#/$defs/{e['extends']}"}], **d}
        has_children = any(c.get("extends") == n for c in m["classes"].values())
        if closed and not has_children:
            d["unevaluatedProperties"] = False
        if e.get("deprecated"):
            d["deprecated"] = True
        cons = [c for c in m["constraints"] if c.get("appliesTo") == n]
        if cons:
            d["$comment"] = "; ".join(f"{c.get('id')}: {c.get('description')}" for c in cons)
        defs[n] = d
    root = opts.get("root")
    schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": f"{hdr.get('namespace', '').rstrip('/')}/{hdr.get('version')}/schema.json",
        "title": hdr.get("title") or hdr.get("name"),
        "description": hdr.get("description", ""),
    }
    if root:
        schema["$ref"] = f"#/$defs/{root}"
    else:
        roots = [n for n, e in m["classes"].items() if not e.get("abstract") and not is_part(m, n)]
        schema["anyOf"] = [{"$ref": f"#/$defs/{n}"} for n in roots]
    schema["$defs"] = defs
    return json.dumps(schema, indent=2, ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------- XSD

XSD_TYPES = {"string": "xs:string", "text": "xs:string", "boolean": "xs:boolean", "integer": "xs:int",
             "long": "xs:long", "decimal": "xs:decimal", "float": "xs:double", "date": "xs:date",
             "dateTime": "xs:dateTime", "time": "xs:time", "duration": "xs:duration", "uri": "xs:anyURI",
             "uuid": "UUIDType", "binary": "xs:base64Binary", "geometry": "xs:anyType"}


def _xdoc(text, ind):
    if not text:
        return []
    return [f"{ind}<xs:annotation><xs:documentation>{xml_escape(str(text))}</xs:documentation></xs:annotation>"]


def _xsd_element(m, name, a, ind, prefix):
    lo, hi = mult(a.get("multiplicity"))
    t = a["type"]
    c = a.get("constraints") or {}
    occ = f' minOccurs="{lo}"' + (f' maxOccurs="{"unbounded" if hi == INF else hi}"' if hi != 1 else "")
    nil = ' nillable="true"' if a.get("voidable") else ""
    doc = a.get("description", "")
    if a.get("deprecated"):
        doc = f"DEPRECATED. {doc}"
    if t == "geometry":
        doc = f"{doc} Geometry {c.get('geometryType', '')} in {c.get('crs', '?')} — replace xs:anyType by a GML property type.".strip()
    facets = []
    if t not in m["enumerations"] and t not in m["datatypes"]:
        for k, f in (("maxLength", "maxLength"), ("minLength", "minLength"), ("pattern", "pattern"),
                     ("min", "minInclusive"), ("max", "maxInclusive"), ("precision", "totalDigits"),
                     ("scale", "fractionDigits")):
            if k in c and t != "geometry":
                facets.append(f'<xs:{f} value="{xml_escape(str(c[k]), {chr(34): "&quot;"})}"/>')
    if t in m["enumerations"] or t in m["datatypes"]:
        typ = f"{prefix}:{t}Type"
    else:
        typ = XSD_TYPES[t] if t != "uuid" else f"{prefix}:UUIDType"
    if facets:
        L = [f'{ind}<xs:element name="{name}"{occ}{nil}>'] + _xdoc(doc, ind + "  ")
        L += [f"{ind}  <xs:simpleType>", f'{ind}    <xs:restriction base="{typ}">']
        L += [f"{ind}      {x}" for x in facets]
        L += [f"{ind}    </xs:restriction>", f"{ind}  </xs:simpleType>", f"{ind}</xs:element>"]
        return L
    if doc:
        return [f'{ind}<xs:element name="{name}" type="{typ}"{occ}{nil}>'] + _xdoc(doc, ind + "  ") + [f"{ind}</xs:element>"]
    return [f'{ind}<xs:element name="{name}" type="{typ}"{occ}{nil}/>']


def export_xsd(m):
    hdr = m["model"]
    ns = hdr.get("namespace", "urn:example")
    p = hdr.get("prefix", "m")
    L = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:{p}="{ns}"',
         f'           targetNamespace="{ns}" elementFormDefault="qualified" version="{hdr.get("version")}">']
    L += _xdoc(hdr.get("description"), "  ")
    L += ['  <xs:simpleType name="UUIDType">',
          '    <xs:restriction base="xs:string"><xs:pattern value="[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"/></xs:restriction>',
          '  </xs:simpleType>',
          '  <xs:complexType name="ReferenceType">',
          '    <xs:annotation><xs:documentation>Reference to another object by identifier or URI.</xs:documentation></xs:annotation>',
          '    <xs:attribute name="href" type="xs:string" use="required"/>',
          '  </xs:complexType>']
    for n, e in m["enumerations"].items():
        L.append(f'  <xs:simpleType name="{n}Type">')
        doc = e.get("description", "")
        codes = [v.get("code") if isinstance(v, dict) else v for v in e.get("values") or []]
        if e.get("extensible"):
            L += _xdoc(f"{doc} Extensible code list. Known values: {', '.join(map(str, codes))}", "    ")
            L += ['    <xs:restriction base="xs:string"/>', "  </xs:simpleType>"]
            continue
        L += _xdoc(doc, "    ")
        L.append('    <xs:restriction base="xs:string">')
        L += [f'      <xs:enumeration value="{xml_escape(str(c))}"/>' for c in codes]
        L += ["    </xs:restriction>", "  </xs:simpleType>"]
    for n, e in m["datatypes"].items():
        L.append(f'  <xs:complexType name="{n}Type">')
        L += _xdoc(e.get("description"), "    ")
        L.append("    <xs:sequence>")
        for an, a in attrs_of(e).items():
            L += _xsd_element(m, an, a, "      ", p)
        L += ["    </xs:sequence>", "  </xs:complexType>"]
    for n, e in m["classes"].items():
        abstract = ' abstract="true"' if e.get("abstract") else ""
        L.append(f'  <xs:complexType name="{n}Type"{abstract}>')
        doc = e.get("description", "")
        cons = [c for c in m["constraints"] if c.get("appliesTo") == n]
        if cons:
            doc += " Constraints: " + "; ".join(f"{c.get('id')}: {c.get('description')}" for c in cons)
        L += _xdoc(doc, "    ")
        body = []
        for an, a in attrs_of(e).items():
            body += _xsd_element(m, an, a, "      " if not e.get("extends") else "          ", p)
        for a in m["associations"]:
            for owner_end, other_end, forward in (("from", "to", True), ("to", "from", False)):
                if a[owner_end]["class"] != n:
                    continue
                if not forward and (a.get("navigable", "from") != "both" or a.get("kind") == "composition"):
                    continue
                role = a[other_end].get("role")
                if not role:
                    continue
                lo, hi = mult(a[other_end].get("multiplicity"))
                typ = f'{p}:{a[other_end]["class"]}Type' if (a.get("kind") == "composition" and forward) else f"{p}:ReferenceType"
                occ = f' minOccurs="{lo}"' + (f' maxOccurs="{"unbounded" if hi == INF else hi}"' if hi != 1 else "")
                ind = "      " if not e.get("extends") else "          "
                body.append(f'{ind}<xs:element name="{role}" type="{typ}"{occ}/>')
        if e.get("extends"):
            L += ["    <xs:complexContent>", f'      <xs:extension base="{p}:{e["extends"]}Type">', "        <xs:sequence>"]
            L += body
            L += ["        </xs:sequence>", "      </xs:extension>", "    </xs:complexContent>"]
        else:
            L.append("    <xs:sequence>")
            L += body
            L.append("    </xs:sequence>")
        L.append("  </xs:complexType>")
        if not e.get("abstract") and not is_part(m, n):
            sub = f' substitutionGroup="{p}:{e["extends"]}"' if e.get("extends") and not m["classes"][e["extends"]].get("abstract") else ""
            L.append(f'  <xs:element name="{n}" type="{p}:{n}Type"{sub}/>')
    L.append("</xs:schema>")
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------- PostgreSQL

def _pg_type(m, a):
    t = a["type"]
    c = a.get("constraints") or {}
    if t == "string":
        return f"varchar({c['maxLength']})" if c.get("maxLength") else "text"
    if t == "decimal":
        if c.get("precision"):
            return f"numeric({c['precision']},{c.get('scale', 0)})"
        return "numeric"
    if t == "geometry":
        gt = c.get("geometryType", "Geometry")
        srid = str(c.get("crs", "EPSG:4326")).split(":")[-1]
        return f"geometry({gt},{srid})" if srid.isdigit() else f"geometry({gt})"
    return {"text": "text", "boolean": "boolean", "integer": "integer", "long": "bigint", "float": "double precision",
            "date": "date", "dateTime": "timestamptz", "time": "time", "duration": "interval", "uri": "text",
            "uuid": "uuid", "binary": "bytea"}[t]


def _pgname(e, default):
    return ((e or {}).get("names") or {}).get("postgres") or snake(default)


def _qlit(s):
    return "'" + str(s).replace("'", "''") + "'"


def export_postgres(m):
    hdr = m["model"]
    sch = snake(hdr.get("name", "model"))
    out, fks, idx, comments, tables = [], [], [], [], {}
    uses_geom = any(a.get("type") == "geometry" for k in ("classes", "datatypes") for e in m[k].values()
                    for a in attrs_of(e).values())
    out.append(f"-- Generated by dmtool from {hdr.get('name')} {hdr.get('version')}. Do not edit; regenerate.")
    out.append("CREATE EXTENSION IF NOT EXISTS pgcrypto;")
    if uses_geom:
        out.append("CREATE EXTENSION IF NOT EXISTS postgis;")
    out.append(f"CREATE SCHEMA IF NOT EXISTS {sch};\n")

    enum_sql = {}
    for n, e in m["enumerations"].items():
        codes = [v.get("code") if isinstance(v, dict) else v for v in e.get("values") or []]
        tn = f"{sch}.{snake(n)}"
        if e.get("extensible"):
            out.append(f"CREATE TABLE {tn} (\n  code text PRIMARY KEY,\n  label text,\n  description text,\n  deprecated boolean NOT NULL DEFAULT false\n);")
            if codes:
                out.append(f"INSERT INTO {tn} (code) VALUES " + ", ".join(f"({_qlit(c)})" for c in codes) + ";")
            enum_sql[n] = ("table", tn)
        else:
            out.append(f"CREATE TYPE {tn} AS ENUM ({', '.join(_qlit(c) for c in codes)});")
            enum_sql[n] = ("type", tn)
        if e.get("description"):
            comments.append(f"COMMENT ON {'TABLE' if e.get('extensible') else 'TYPE'} {tn} IS {_qlit(e['description'])};")
    out.append("")

    def pk_info(cname):
        ident = identifier(m, cname)
        if ident:
            a = all_attrs(m, cname)[ident["attribute"]]
            return snake(ident["attribute"]), _pg_type(m, a), ident
        return "id", "bigint", None

    def column_defs(table, cname, attrs, prefix="", parent_required=True):
        cols = []
        for an, a in attrs.items():
            lo, hi = mult(a.get("multiplicity"))
            cn = prefix + _pgname(a, an)
            t = a["type"]
            required = lo >= 1 and not a.get("voidable")
            notnull = " NOT NULL" if required and parent_required else ""
            if hi > 1:
                # child table for multi-valued attributes
                owner_pk, owner_type, _ = pk_info(cname) if cname in m["classes"] else ("id", "bigint", None)
                ct = f"{table}_{cn}"
                owner_col = f"{snake(root_class(m, cname)) if cname in m['classes'] else 'owner'}_{owner_pk}"
                ccols = [f"  {owner_col} {owner_type} NOT NULL", "  ord integer NOT NULL"]
                if t in m["datatypes"]:
                    ccols += [c for c, _ in column_defs(ct, t, attrs_of(m["datatypes"][t]))]
                else:
                    ccols.append(f"  value {_col_type(t, a)} NOT NULL")
                ccols.append(f"  PRIMARY KEY ({owner_col}, ord)")
                out.append(f"CREATE TABLE {ct} (\n" + ",\n".join(ccols) + "\n);")
                fks.append(f"ALTER TABLE {ct} ADD FOREIGN KEY ({owner_col}) REFERENCES {table} ({owner_pk}) ON DELETE CASCADE;")
                if a.get("description"):
                    comments.append(f"COMMENT ON TABLE {ct} IS {_qlit(a['description'])};")
                continue
            if t in m["datatypes"]:
                sub = column_defs(table, t, attrs_of(m["datatypes"][t]), prefix=cn + "_",
                                  parent_required=required and parent_required)
                cols += sub
                continue
            uniq = " UNIQUE" if a.get("unique") else ""
            cols.append((f"  {cn} {_col_type(t, a)}{notnull}{uniq}", (cn, a.get("description"))))
        return cols

    def _col_type(t, a):
        if t in enum_sql:
            kind, tn = enum_sql[t]
            if kind == "table":
                return "text"
            return tn
        return _pg_type(m, a)

    # class tables
    for n, e in m["classes"].items():
        tn = f"{sch}.{_pgname(e, n)}"
        tables[n] = tn
    for n, e in m["classes"].items():
        tn = tables[n]
        pk_col, pk_type, ident = pk_info(n)
        cols = []
        own = dict(attrs_of(e))
        if e.get("extends"):
            ptn = tables[e["extends"]]
            cols.append((f"  {pk_col} {pk_type} PRIMARY KEY", (pk_col, None)))
            fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({pk_col}) REFERENCES {ptn} ({pk_col}) ON DELETE CASCADE;")
            own.pop(ident["attribute"] if ident else "", None)
        elif ident:
            a = own.pop(ident["attribute"])
            default = " DEFAULT gen_random_uuid()" if ident.get("strategy") == "uuid" and a["type"] == "uuid" else ""
            if ident.get("strategy") == "sequence" and a["type"] in ("integer", "long"):
                default = " GENERATED ALWAYS AS IDENTITY"
            cols.append((f"  {pk_col} {pk_type}{default} PRIMARY KEY", (pk_col, a.get("description"))))
        else:
            cols.append(("  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY", ("id", "Surrogate key")))
        cols += column_defs(tn, n, own)
        for an, a in own.items():
            if a.get("type") in enum_sql and enum_sql[a["type"]][0] == "table" and mult(a.get("multiplicity"))[1] == 1:
                fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({_pgname(a, an)}) REFERENCES {enum_sql[a['type']][1]} (code);")
        hist = e.get("history") or {}
        if not e.get("extends"):
            if hist.get("validTime"):
                cols.append(("  valid_from timestamptz NOT NULL DEFAULT now()", ("valid_from", "Start of validity (valid time)")))
                cols.append(("  valid_to timestamptz", ("valid_to", "End of validity (valid time); NULL = open")))
            if hist.get("deletion") == "logical":
                cols.append(("  deleted_at timestamptz", ("deleted_at", "Logical deletion timestamp")))
        # FK columns from associations
        for a in m["associations"]:
            f, t = a["from"], a["to"]
            fm, tm = mult(f.get("multiplicity")), mult(t.get("multiplicity"))
            comp = a.get("kind") == "composition"
            if comp and t["class"] == n:
                owner = f["class"]
                opk, otype, _ = pk_info(owner)
                col = f"{snake(f.get('role') or owner)}_{opk}"
                cols.append((f"  {col} {otype} NOT NULL", (col, a.get("description"))))
                fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({col}) REFERENCES {tables[owner]} ({opk}) ON DELETE CASCADE;")
                idx.append(f"CREATE INDEX ON {tn} ({col});")
                if a.get("ordered"):
                    cols.append(("  ord integer NOT NULL DEFAULT 0", ("ord", "Position within the owning collection")))
            elif not comp and f["class"] == n and tm[1] == 1:
                tgt = t["class"]
                tpk, ttype, _ = pk_info(tgt)
                col = f"{snake(t.get('role') or tgt)}_{tpk}"
                nn = " NOT NULL" if tm[0] >= 1 else ""
                cols.append((f"  {col} {ttype}{nn}", (col, a.get("description"))))
                fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({col}) REFERENCES {tables[tgt]} ({tpk});")
                idx.append(f"CREATE INDEX ON {tn} ({col});")
            elif not comp and t["class"] == n and fm[1] == 1 and tm[1] > 1:
                src = f["class"]
                spk, stype, _ = pk_info(src)
                col = f"{snake(f.get('role') or src)}_{spk}"
                nn = " NOT NULL" if fm[0] >= 1 else ""
                cols.append((f"  {col} {stype}{nn}", (col, a.get("description"))))
                fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({col}) REFERENCES {tables[src]} ({spk});")
                idx.append(f"CREATE INDEX ON {tn} ({col});")
        out.append(f"CREATE TABLE {tn} (\n" + ",\n".join(c for c, _ in cols) + "\n);")
        if e.get("description"):
            comments.append(f"COMMENT ON TABLE {tn} IS {_qlit(e['description'])};")
        for _, (cn, d) in cols:
            if d:
                comments.append(f"COMMENT ON COLUMN {tn}.{cn} IS {_qlit(d)};")
        if not e.get("extends") and hist.get("mode") in ("audit", "versioned", "bitemporal"):
            out.append(f"CREATE TABLE {tn}_history (\n  history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n"
                       f"  operation char(1) NOT NULL CHECK (operation IN ('I','U','D')),\n"
                       f"  recorded_at timestamptz NOT NULL DEFAULT now(),\n  recorded_by text,\n"
                       f"  row_data jsonb NOT NULL\n);")
            idx.append(f"CREATE INDEX ON {tn}_history ((row_data->>{_qlit(pk_col)}), recorded_at);")
            hist_note = f"History ({hist.get('mode')}) of {n}; fill via trigger on {tn}."
            comments.append(f"COMMENT ON TABLE {tn}_history IS {_qlit(hist_note)};")
    # many-to-many join tables
    for a in m["associations"]:
        f, t = a["from"], a["to"]
        fm, tm = mult(f.get("multiplicity")), mult(t.get("multiplicity"))
        if a.get("kind") != "composition" and fm[1] > 1 and tm[1] > 1:
            fpk, ftype, _ = pk_info(f["class"])
            tpk, ttype, _ = pk_info(t["class"])
            jt = f"{sch}.{snake(f['class'])}_{snake(t.get('role') or t['class'])}"
            fc, tc = f"{snake(f['class'])}_{fpk}", f"{snake(t['class'])}_{tpk}"
            if fc == tc:
                tc = f"{snake(t.get('role') or 'target')}_{tpk}"
            out.append(f"CREATE TABLE {jt} (\n  {fc} {ftype} NOT NULL,\n  {tc} {ttype} NOT NULL,\n  PRIMARY KEY ({fc}, {tc})\n);")
            fks.append(f"ALTER TABLE {jt} ADD FOREIGN KEY ({fc}) REFERENCES {tables[f['class']]} ({fpk}) ON DELETE CASCADE;")
            fks.append(f"ALTER TABLE {jt} ADD FOREIGN KEY ({tc}) REFERENCES {tables[t['class']]} ({tpk}) ON DELETE CASCADE;")
            idx.append(f"CREATE INDEX ON {jt} ({tc});")
    for c in m["constraints"]:
        out.append(f"-- Constraint {c.get('id')} on {c.get('appliesTo')}: {c.get('description')} (not enforced; implement as CHECK/trigger if required)")
    out.append("")
    out += fks + [""] + idx + [""] + comments
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------- diff

WIDENING = {("integer", "long"), ("integer", "decimal"), ("long", "decimal"), ("integer", "float"),
            ("string", "text"), ("date", "dateTime")}
LEVEL = {"patch": 0, "minor": 1, "major": 2}


def _deprecated(e):
    return bool((e or {}).get("deprecated"))


def _cmp_mult(path, old, new, changes):
    o, n = mult(old), mult(new)
    if o == n or o is None or n is None:
        return
    s = f"multiplicity {mult_str(*o)} → {mult_str(*n)}"
    if n[0] > o[0]:
        changes.append(("major", path, s + " (lower bound raised: existing data may lack values)"))
    elif n[1] < o[1]:
        changes.append(("major", path, s + " (upper bound lowered: existing data may have too many values)"))
    elif o[1] == 1 and n[1] > 1:
        changes.append(("major", path, s + " (single value becomes a list: consumers and storage structure change)"))
    elif n[0] < o[0]:
        changes.append(("minor", path, s + " (now optional — RISK: consumers may expect the value)"))
    else:
        changes.append(("minor", path, s + " (upper bound raised — RISK for consumers)"))


def _cmp_constraints(path, oc, nc, changes):
    oc, nc = oc or {}, nc or {}
    for k in sorted(set(oc) | set(nc)):
        ov, nv = oc.get(k), nc.get(k)
        if ov == nv:
            continue
        msg = f"constraint {k}: {ov} → {nv}"
        if k in ("maxLength", "max", "precision"):
            relaxed = nv is None or (ov is not None and nv > ov)
        elif k in ("minLength", "min"):
            relaxed = nv is None or (ov is not None and nv < ov)
        elif k == "pattern":
            relaxed = nv is None
        elif k in ("unit", "crs", "geometryType", "scale"):
            changes.append(("major", path, msg + " (semantic change of values)"))
            continue
        else:
            changes.append(("minor", path, msg))
            continue
        changes.append(("minor", path, msg + " (relaxed — RISK for consumers)") if relaxed
                       else ("major", path, msg + " (tightened: existing data may violate it)"))


def _cmp_attr(path, o, n, changes, mo, mn):
    if o.get("type") != n.get("type"):
        pair = (o.get("type"), n.get("type"))
        if pair in WIDENING:
            changes.append(("minor", path, f"type widened {pair[0]} → {pair[1]} (RISK for consumers)"))
        else:
            changes.append(("major", path, f"type changed {pair[0]} → {pair[1]}"))
    _cmp_mult(path, o.get("multiplicity"), n.get("multiplicity"), changes)
    _cmp_constraints(path, o.get("constraints"), n.get("constraints"), changes)
    if bool(o.get("voidable")) != bool(n.get("voidable")):
        changes.append(("minor", path, "now voidable (RISK for consumers)") if n.get("voidable")
                       else ("major", path, "no longer voidable: existing nil values become invalid"))
    if bool(o.get("unique")) != bool(n.get("unique")):
        changes.append(("major", path, "unique added: existing duplicates become invalid") if n.get("unique")
                       else ("minor", path, "unique removed"))
    if bool(o.get("derived")) != bool(n.get("derived")):
        changes.append(("major", path, f"derived {o.get('derived', False)} → {n.get('derived', False)}"))
    if not _deprecated(o) and _deprecated(n):
        changes.append(("minor", path, "deprecated"))
    if o.get("description") != n.get("description"):
        changes.append(("patch", path, "description changed"))


def _cmp_attr_sets(owner, oa, na, changes, mo, mn):
    for an in oa:
        if an not in na:
            changes.append(("major", f"{owner}.{an}", "attribute removed" +
                            (" (was deprecated)" if _deprecated(oa[an]) else "")))
    added = [an for an in na if an not in oa]
    for an in added:
        a = na[an]
        lo = (mult(a.get("multiplicity")) or (1, 1))[0]
        if lo >= 1 and not a.get("voidable") and "default" not in a:
            changes.append(("major", f"{owner}.{an}", "mandatory attribute added: existing data lacks it "
                            "(add as optional or with a default to stay compatible)"))
        else:
            changes.append(("minor", f"{owner}.{an}", "optional attribute added (RISK: strict consumers with closed content)"))
    removed = [an for an in oa if an not in na]
    for r in removed:
        for ad in added:
            if oa[r].get("type") == na[ad].get("type"):
                changes.append(("patch", f"{owner}.{ad}", f"hint: may be a rename of '{r}' — prefer add + deprecate"))
    for an in oa:
        if an in na:
            _cmp_attr(f"{owner}.{an}", oa[an], na[an], changes, mo, mn)


def diff(mo, mn):
    changes = []
    for kind in ("enumerations", "datatypes", "classes"):
        for n in mo[kind]:
            if n not in mn[kind]:
                changes.append(("major", n, f"{kind[:-1] if kind != 'classes' else 'class'} removed"
                                + (" (was deprecated)" if _deprecated(mo[kind][n]) else "")))
        for n in mn[kind]:
            if n not in mo[kind]:
                changes.append(("minor", n, f"{kind[:-1] if kind != 'classes' else 'class'} added"))
    for n, e in mo["enumerations"].items():
        if n not in mn["enumerations"]:
            continue
        ne = mn["enumerations"][n]
        oc = {(v.get("code") if isinstance(v, dict) else v): v for v in e.get("values") or []}
        nc = {(v.get("code") if isinstance(v, dict) else v): v for v in ne.get("values") or []}
        for c in oc:
            if c not in nc:
                changes.append(("major", f"{n}.{c}", "enum value removed (deprecate instead)"))
            elif not _deprecated(oc[c] if isinstance(oc[c], dict) else {}) and _deprecated(nc[c] if isinstance(nc[c], dict) else {}):
                changes.append(("minor", f"{n}.{c}", "enum value deprecated"))
        for c in nc:
            if c not in oc:
                risk = "" if ne.get("extensible") else " (RISK: consumers with exhaustive handling of a closed enum)"
                changes.append(("minor", f"{n}.{c}", "enum value added" + risk))
        if bool(e.get("extensible")) != bool(ne.get("extensible")):
            changes.append(("minor", n, "enumeration made extensible") if ne.get("extensible")
                           else ("major", n, "enumeration closed: values outside the list become invalid"))
        if e.get("description") != ne.get("description"):
            changes.append(("patch", n, "description changed"))
    for n, e in mo["datatypes"].items():
        if n in mn["datatypes"]:
            _cmp_attr_sets(n, attrs_of(e), attrs_of(mn["datatypes"][n]), changes, mo, mn)
    for n, e in mo["classes"].items():
        if n not in mn["classes"]:
            continue
        ne = mn["classes"][n]
        if e.get("extends") != ne.get("extends"):
            changes.append(("major", n, f"extends {e.get('extends')} → {ne.get('extends')}"))
        if bool(e.get("abstract")) != bool(ne.get("abstract")):
            changes.append(("major" if ne.get("abstract") else "minor", n,
                            "made abstract" if ne.get("abstract") else "no longer abstract"))
        if (e.get("identifier") or {}) != (ne.get("identifier") or {}):
            changes.append(("major", n, f"identifier {e.get('identifier')} → {ne.get('identifier')}"))
        if (e.get("history") or {}) != (ne.get("history") or {}):
            changes.append(("major", n, f"history {e.get('history')} → {ne.get('history')} "
                            "(data historisation changes need a migration; review)"))
        if not _deprecated(e) and _deprecated(ne):
            changes.append(("minor", n, "class deprecated"))
        if e.get("description") != ne.get("description"):
            changes.append(("patch", n, "description changed"))
        if (e.get("nfr") or {}) != (ne.get("nfr") or {}):
            changes.append(("patch", n, "non-functional requirements changed (check physical design)"))
        _cmp_attr_sets(n, attrs_of(e), attrs_of(ne), changes, mo, mn)

    def akey(a):
        return a.get("name") or f"{a['from']['class']}.{a['to'].get('role')}"
    oa = {akey(a): a for a in mo["associations"]}
    na = {akey(a): a for a in mn["associations"]}
    for k, a in oa.items():
        if k not in na:
            changes.append(("major", k, "association removed"))
    for k, a in na.items():
        if k not in oa:
            lo_to = (mult(a["to"].get("multiplicity")) or (1, 1))[0]
            lo_from = (mult(a["from"].get("multiplicity")) or (0, 0))[0] if a.get("navigable") == "both" else 0
            if lo_to >= 1 or lo_from >= 1:
                changes.append(("major", k, "mandatory association added: existing objects lack the link"))
            else:
                changes.append(("minor", k, "optional association added (RISK: strict consumers)"))
            continue
        o = oa[k]
        if o.get("kind", "reference") != a.get("kind", "reference"):
            changes.append(("major", k, f"kind {o.get('kind', 'reference')} → {a.get('kind', 'reference')}"))
        for end in ("from", "to"):
            if o[end]["class"] != a[end]["class"]:
                changes.append(("major", f"{k}.{end}", f"class {o[end]['class']} → {a[end]['class']}"))
            if o[end].get("role") != a[end].get("role"):
                changes.append(("major", f"{k}.{end}", f"role renamed {o[end].get('role')} → {a[end].get('role')}"))
            _cmp_mult(f"{k}.{end}", o[end].get("multiplicity"), a[end].get("multiplicity"), changes)
        if not _deprecated(o) and _deprecated(a):
            changes.append(("minor", k, "association deprecated"))
    oc = {c.get("id"): c for c in mo["constraints"]}
    nc = {c.get("id"): c for c in mn["constraints"]}
    for cid in nc:
        if cid not in oc:
            changes.append(("major", f"constraint {cid}", "constraint added: existing data may violate it"))
        elif oc[cid].get("expression") != nc[cid].get("expression"):
            changes.append(("major", f"constraint {cid}", "constraint changed — review whether it is tightened"))
    for cid in oc:
        if cid not in nc:
            changes.append(("minor", f"constraint {cid}", "constraint removed"))
    if mo["model"].get("namespace") != mn["model"].get("namespace"):
        changes.append(("major", "model.namespace", "namespace changed"))
    return changes


def recommend(old_version, new_version, changes):
    level = max((LEVEL[c[0]] for c in changes), default=-1)
    try:
        ma, mi, pa = (int(x) for x in str(old_version).split("-")[0].split("."))
    except Exception:
        return None, None, level
    if level == 2:
        rec = f"{ma + 1}.0.0" if ma >= 1 else f"0.{mi + 1}.0"
    elif level == 1:
        rec = f"{ma}.{mi + 1}.0"
    elif level == 0:
        rec = f"{ma}.{mi}.{pa + 1}"
    else:
        rec = str(old_version)
    ok = None
    try:
        nv = tuple(int(x) for x in str(new_version).split("-")[0].split("."))
        ok = nv >= tuple(int(x) for x in rec.split("."))
    except Exception:
        pass
    return rec, ok, level


# --------------------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate"); v.add_argument("model")
    d = sub.add_parser("diagram"); d.add_argument("model"); d.add_argument("-o", "--output")
    e = sub.add_parser("export"); e.add_argument("model"); e.add_argument("-o", "--output")
    e.add_argument("--format", required=True, choices=["jsonschema", "xsd", "postgres"])
    df = sub.add_parser("diff"); df.add_argument("old"); df.add_argument("new"); df.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    if args.cmd == "validate":
        m = load(args.model)
        errors, warnings, info = validate(m, args.model)
        for x in errors:
            print(f"ERROR   {x}")
        for x in warnings:
            print(f"WARNING {x}")
        for x in info:
            print(f"INFO    {x}")
        print(f"\n{len(errors)} error(s), {len(warnings)} warning(s), {len(info)} note(s)")
        sys.exit(1 if errors else 0)

    if args.cmd in ("diagram", "export"):
        m = load(args.model)
        errors, _, _ = validate(m, args.model)
        if errors:
            print("Model has validation errors; run 'validate' first:", *errors, sep="\n  ", file=sys.stderr)
            sys.exit(1)
        text = diagram(m) if args.cmd == "diagram" else \
            {"jsonschema": export_jsonschema, "xsd": export_xsd, "postgres": export_postgres}[args.format](m)
        if args.output:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(text, encoding="utf-8")
            print(f"wrote {args.output}")
        else:
            sys.stdout.write(text)
        return

    if args.cmd == "diff":
        mo, mn = load(args.old), load(args.new)
        changes = diff(mo, mn)
        ov, nv = mo["model"].get("version"), mn["model"].get("version")
        rec, ok, level = recommend(ov, nv, changes)
        if args.json:
            print(json.dumps({"from": ov, "to": nv, "recommendedVersion": rec, "versionOk": ok,
                              "changes": [{"level": l, "element": p, "change": c} for l, p, c in changes]},
                             indent=2, ensure_ascii=False))
            return
        order = {"major": 0, "minor": 1, "patch": 2}
        print(f"Model diff {ov} → {nv}: {len(changes)} change(s)\n")
        for l, p, c in sorted(changes, key=lambda x: (order[x[0]], x[1])):
            tag = {"major": "BREAKING", "minor": "compatible", "patch": "doc"}[l]
            print(f"  [{tag:10}] {p}: {c}")
        print()
        if rec:
            print(f"Recommended version: {rec}" + ("" if ok is None else
                  ("  (new version OK)" if ok else f"  — model.version {nv} is too low")))
        if level == 2:
            print("Breaking changes present: get an explicit decision, log it, and write migration notes.")


if __name__ == "__main__":
    main()
