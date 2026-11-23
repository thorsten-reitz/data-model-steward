#!/usr/bin/env python3
"""dmtool — create, validate, diagram, export, diff and release canonical data models (model.yaml).

Usage:
  dmtool.py init     [dir] [--name NAME] [--namespace URI] [--languages en,de]
  dmtool.py validate <model.yaml>
  dmtool.py diagram  <model.yaml> [-o out.mmd]
  dmtool.py export   <model.yaml> --format jsonschema|xsd|postgres|all [-o out] [--lang de]
  dmtool.py diff     <old.yaml> <new.yaml> [--consumers strict|tolerant] [--json]
  dmtool.py release  [dir] [--version X.Y.Z] [--date YYYY-MM-DD] [--dry-run]

`dir` is the model workspace (default: ./datamodel). Requires PyYAML.
Format: references/model-format.md
"""
import argparse
import datetime
import json
import re
import shutil
import sys
import unicodedata
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("dmtool needs PyYAML: pip install pyyaml")

PRIMITIVES = {"string", "text", "boolean", "integer", "long", "decimal", "float", "date",
              "dateTime", "time", "duration", "uri", "uuid", "binary", "geometry"}
TARGETS = ("jsonschema", "xsd", "postgres")
EXPORT_FILES = {"jsonschema": "schema.json", "xsd": "schema.xsd", "postgres": "schema.sql"}
NAME_TARGETS = {"json", "xsd", "postgres"}
MULT_RE = re.compile(r"^(\d+)(?:\.\.(\d+|\*))?$|^\*$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
UPPER_CAMEL = re.compile(r"^[A-Z][A-Za-z0-9]*$")
LOWER_CAMEL = re.compile(r"^[a-z][A-Za-z0-9]*$")
INF = float("inf")


# --------------------------------------------------------------------------- names and languages

TRANSLIT = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss",
                          "æ": "ae", "Æ": "Ae", "ø": "oe", "Ø": "Oe", "å": "aa", "Å": "Aa",
                          "œ": "oe", "Œ": "Oe", "þ": "th", "Þ": "Th", "ð": "d", "Ð": "D"})


def ident(name):
    """ASCII-safe identifier: transliterate (ä→ae, ß→ss, é→e …) and replace other characters by '_'."""
    s = str(name).translate(TRANSLIT)
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    s = re.sub(r"[^A-Za-z0-9_]", "_", s)
    return s if s and not s[0].isdigit() else "_" + s


def tname(e, default, target):
    """Name of an element in an export target: explicit `names: {target: …}` or the transliterated default."""
    return ((e or {}).get("names") or {}).get(target) or ident(default)


def doc_langs(m):
    """Documentation languages, default language first."""
    hdr = m["model"]
    L = hdr.get("languages") or {}
    docs = L.get("documentation") if isinstance(L, dict) else None
    if isinstance(docs, str):
        docs = [docs]
    if not docs:
        docs = [(hdr.get("conventions") or {}).get("language") or (L.get("identifiers") if isinstance(L, dict) else None) or "en"]
    return [str(x) for x in docs]


def default_lang(m):
    return doc_langs(m)[0]


def text(m, v, lang=None):
    """A documentation text in `lang`, falling back to the default language, then to any language."""
    if v is None:
        return ""
    if isinstance(v, dict):
        for lg in (lang, default_lang(m)):
            if lg and v.get(lg):
                return str(v[lg])
        return str(next((x for x in v.values() if x), ""))
    return str(v)


def texts(m, v):
    """All translations of a documentation text as {lang: text}."""
    if v is None:
        return {}
    if isinstance(v, dict):
        return {str(k): str(x) for k, x in v.items() if x}
    return {default_lang(m): str(v)}


# --------------------------------------------------------------------------- model access

def load(path):
    with open(path, encoding="utf-8") as f:
        return load_from(yaml.safe_load(f))


def load_from(m):
    m = m or {}
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


def values_of(enum):
    return [v if isinstance(v, dict) else {"code": v} for v in enum.get("values") or []]


def codes_of(enum):
    return [v.get("code") for v in values_of(enum)]


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
        ident_ = m["classes"][c].get("identifier")
        if ident_ and ident_.get("attribute"):
            return ident_
        c = m["classes"][c].get("extends")
    return None


def root_class(m, cname):
    c, seen = cname, set()
    while m["classes"].get(c, {}).get("extends") and c not in seen:
        seen.add(c)
        c = m["classes"][c]["extends"]
    return c


def element(m, name):
    return m["classes"].get(name) or m["datatypes"].get(name) or m["enumerations"].get(name) or {}


def snake(name):
    s = re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", ident(name))
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
    return s.lower()


def is_part(m, cname):
    return any(a.get("kind") == "composition" and a["to"]["class"] == cname for a in m["associations"])


def semver(v):
    try:
        return tuple(int(x) for x in str(v).split("-")[0].split("."))
    except ValueError:
        return None


# --------------------------------------------------------------------------- validate

def validate(m, model_path=None, as_released=False):
    errors, warnings, info = [], [], []
    hdr = m["model"]
    for k in ("name", "version", "namespace"):
        if not hdr.get(k):
            errors.append(f"model.{k} is missing")
    if hdr.get("version") and not SEMVER_RE.match(str(hdr["version"])):
        errors.append(f"model.version '{hdr['version']}' is not semantic (x.y.z)")
    if hdr.get("status") not in (None, "draft", "released"):
        errors.append("model.status must be draft or released")
    if hdr.get("languages") is not None and not isinstance(hdr["languages"], dict):
        errors.append("model.languages must be a mapping {identifiers, documentation}")
    if (hdr.get("compatibility") or {}).get("consumers") not in (None, "strict", "tolerant"):
        errors.append("model.compatibility.consumers must be strict or tolerant")
    for t in hdr.get("targets") or []:
        if t not in TARGETS:
            info.append(f"model.targets: '{t}' has no generator in dmtool (write it by hand, see references/exports.md)")

    dl = doc_langs(m)
    missing = {lg: [] for lg in dl}
    renamed = []
    proposed = []
    names = {}

    def check_text(path, v):
        if v is None:
            return
        if isinstance(v, dict):
            for k in v:
                if str(k) not in dl:
                    warnings.append(f"{path}: text in undeclared language '{k}' (declare it in model.languages.documentation)")
            have = {str(k) for k, x in v.items() if x}
        elif isinstance(v, str):
            have = {dl[0]}
        else:
            errors.append(f"{path}: text must be a string or a mapping {{lang: text}}")
            return
        for lg in dl:
            if lg not in have:
                missing[lg].append(path)

    def note_ident(path, n):
        if ident(n) != n:
            renamed.append(f"{path} → {ident(n)}")

    def check_names(path, e):
        nm = e.get("names")
        if nm is None:
            return
        if not isinstance(nm, dict):
            errors.append(f"{path}: names must be a mapping {{json|xsd|postgres: name}}")
            return
        for k in nm:
            if k not in NAME_TARGETS:
                warnings.append(f"{path}: names.{k} is not a known target ({', '.join(sorted(NAME_TARGETS))})")

    def check_common(path, e):
        if not isinstance(e, dict):
            errors.append(f"{path}: expected a mapping")
            return False
        if not e.get("description"):
            warnings.append(f"{path}: no description")
        check_text(f"{path}.description", e.get("description"))
        check_text(f"{path}.label", e.get("label"))
        check_names(path, e)
        if e.get("status") == "proposed":
            proposed.append(path)
        dep = e.get("deprecated")
        if dep is not None and not isinstance(dep, (dict, bool)):
            errors.append(f"{path}: deprecated must be a mapping {{since, reason, replacedBy}}")
        return True

    for kind in ("classes", "datatypes", "enumerations"):
        for n in m[kind]:
            if n in names:
                errors.append(f"'{n}' defined as both {names[n]} and {kind}")
            names[n] = kind
            if n in PRIMITIVES:
                errors.append(f"'{n}' shadows a primitive type")
            note_ident(n, n)
            if not UPPER_CAMEL.match(ident(n)):
                warnings.append(f"{kind[:-1] if kind != 'classes' else 'class'} '{n}' is not UpperCamelCase")

    def check_attr(path, a):
        if not isinstance(a, dict):
            errors.append(f"{path}: expected a mapping")
            return
        if not a.get("description"):
            info.append(f"{path}: no description")
        check_text(f"{path}.description", a.get("description"))
        check_text(f"{path}.label", a.get("label"))
        check_names(path, a)
        if a.get("status") == "proposed":
            proposed.append(path)
        t = a.get("type")
        if not t:
            errors.append(f"{path}: type missing")
        elif t in m["classes"]:
            errors.append(f"{path}: type '{t}' is a class — use an association instead")
        elif t not in PRIMITIVES and t not in m["datatypes"] and t not in m["enumerations"]:
            errors.append(f"{path}: unknown type '{t}'")
        mm = mult(a.get("multiplicity"))
        if mm is None:
            errors.append(f"{path}: bad multiplicity '{a.get('multiplicity')}'")
        elif mm[0] > mm[1]:
            errors.append(f"{path}: lower bound > upper bound")
        an = path.split(".")[-1]
        note_ident(path, an)
        if not LOWER_CAMEL.match(ident(an)):
            warnings.append(f"{path}: attribute name not lowerCamelCase")
        if t == "geometry" and not (a.get("constraints") or {}).get("crs"):
            warnings.append(f"{path}: geometry without crs")
        x = a.get("xml") or {}
        if x and not isinstance(x, dict):
            errors.append(f"{path}: xml must be a mapping {{attribute, type}}")
        elif x.get("attribute"):
            if t in m["datatypes"] or t == "geometry":
                errors.append(f"{path}: xml.attribute needs a simple type (not '{t}')")
            if mm and mm[1] > 1:
                errors.append(f"{path}: xml.attribute needs upper bound 1")

    for n, e in m["enumerations"].items():
        if not check_common(n, e):
            continue
        ct = e.get("codeType", "string")
        if ct not in ("string", "integer"):
            errors.append(f"{n}: codeType must be string or integer")
        vals = values_of(e)
        if not vals and not e.get("extensible"):
            errors.append(f"{n}: closed enumeration without values")
        codes = [v.get("code") for v in vals]
        dup = {str(c) for c in codes if codes.count(c) > 1}
        if dup:
            errors.append(f"{n}: duplicate codes {sorted(dup)}")
        if ct == "integer" and any(not isinstance(c, int) or isinstance(c, bool) for c in codes):
            errors.append(f"{n}: codeType integer but not all codes are integers")
        for v in vals:
            check_text(f"{n}.{v.get('code')}.label", v.get("label"))
            check_text(f"{n}.{v.get('code')}.description", v.get("description"))

    for n, e in m["datatypes"].items():
        if check_common(n, e):
            for an, a in attrs_of(e).items():
                check_attr(f"{n}.{an}", a)

    for n, e in m["classes"].items():
        if not check_common(n, e):
            continue
        p = e.get("extends")
        if p and p not in m["classes"]:
            errors.append(f"{n}: extends unknown class '{p}'")
        seen, c = set(), n
        while c in m["classes"] and m["classes"][c].get("extends"):
            if c in seen:
                errors.append(f"{n}: inheritance cycle")
                break
            seen.add(c)
            c = m["classes"][c]["extends"]
        for an, a in attrs_of(e).items():
            check_attr(f"{n}.{an}", a)
            if p and an in all_attrs(m, p):
                errors.append(f"{n}.{an}: redefines inherited attribute")
        ide = e.get("identifier")
        if ide:
            ia = ide.get("attribute")
            if ia and ia not in all_attrs(m, n):
                errors.append(f"{n}: identifier attribute '{ia}' not found")
            elif ia and (mult(all_attrs(m, n)[ia].get("multiplicity")) or (1, 1)) != (1, 1):
                errors.append(f"{n}: identifier '{ia}' must have multiplicity 1")
            if ide.get("strategy") not in (None, "uuid", "natural", "sequence", "uri"):
                errors.append(f"{n}: unknown identifier strategy '{ide.get('strategy')}'")
        elif not p and not is_part(m, n):
            warnings.append(f"{n}: no identifier defined (a surrogate key will be generated)")
        hist = e.get("history") or {}
        if hist.get("mode") not in (None, "none", "audit", "versioned", "bitemporal"):
            errors.append(f"{n}: unknown history.mode '{hist.get('mode')}'")
        if "history" not in e and not p and not is_part(m, n):
            info.append(f"{n}: history requirements not recorded yet")
        if "nfr" not in e and not p and not is_part(m, n):
            info.append(f"{n}: non-functional requirements (volume etc.) not recorded yet")

    roles, assoc_names = {}, set()
    for i, a in enumerate(m["associations"]):
        label = a.get("name") or f"associations[{i}]"
        if a.get("name") in assoc_names:
            errors.append(f"{label}: duplicate association name")
        assoc_names.add(a.get("name"))
        if not a.get("name"):
            warnings.append(f"{label}: unnamed association")
        check_text(f"{label}.description", a.get("description"))
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
            else:
                note_ident(f"{label}.{end_name}.role", end["role"])
            check_names(f"{label}.{end_name}", end)
        if isinstance(a.get("from"), dict) and isinstance(a.get("to"), dict):
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
        cid = c.get("id")
        if not cid:
            warnings.append("constraint without id")
        if c.get("appliesTo") and c["appliesTo"] not in names:
            errors.append(f"constraint {cid}: appliesTo unknown '{c['appliesTo']}'")
        if c.get("enforcement") not in (None, "enforced", "warning", "documented"):
            errors.append(f"constraint {cid}: enforcement must be enforced, warning or documented")
        if c.get("scope") not in (None, "all", "new"):
            errors.append(f"constraint {cid}: scope must be all or new")
        check_text(f"constraint {cid}.description", c.get("description"))

    if model_path:
        sfile = Path(model_path).parent / "sources.md"
        if sfile.exists():
            known = set(re.findall(r"\bS\d+\b", sfile.read_text(encoding="utf-8")))
            used = set(re.findall(r"\bS\d+\b", yaml.safe_dump(_collect_sources(m))))
            missing_src = sorted(used - known)
            if missing_src:
                warnings.append(f"sources referenced but not in sources.md: {missing_src}")

    for lg, paths in missing.items():
        if not paths:
            continue
        msg = (f"{len(paths)} text(s) have no '{lg}' version: "
               f"{', '.join(paths[:8])}{' …' if len(paths) > 8 else ''}")
        if lg == dl[0]:
            warnings.append(msg + " (default language)")
        elif len(dl) > 1:
            (errors if as_released or hdr.get("status") == "released" else warnings).append(msg)
    if renamed:
        info.append("identifiers are transliterated in exports (set names.<target> to override): "
                    + ", ".join(renamed[:10]) + (" …" if len(renamed) > 10 else ""))
    if proposed:
        (errors if as_released or hdr.get("status") == "released" else warnings).append(
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
        L.append(f"  class {ident(n)} {{\n    <<enumeration>>")
        for c in codes_of(e):
            L.append(f"    {c}")
        L.append("  }")
    for kind, stereo in (("datatypes", "datatype"), ("classes", None)):
        for n, e in m[kind].items():
            L.append(f"  class {ident(n)} {{")
            if stereo:
                L.append(f"    <<{stereo}>>")
            elif e.get("abstract"):
                L.append("    <<abstract>>")
            for an, a in attrs_of(e).items():
                ms = a.get("multiplicity", "1")
                suffix = "" if str(ms) == "1" else f" [{ms}]"
                L.append(f"    +{ident(a.get('type'))} {ident(an)}{suffix}")
            L.append("  }")
    for n, e in m["classes"].items():
        if e.get("extends"):
            L.append(f"  {ident(e['extends'])} <|-- {ident(n)}")
    for a in m["associations"]:
        f, t = a["from"], a["to"]
        arrow = {"composition": "*--", "aggregation": "o--"}.get(a.get("kind"), "-->")
        L.append(f'  {ident(f["class"])} "{f.get("multiplicity", "1")}" {arrow} "{t.get("multiplicity", "1")}" '
                 f'{ident(t["class"])} : {ident(t.get("role") or a.get("name", ""))}')
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


def export_jsonschema(m, lang=None):
    hdr = m["model"]
    L = lang or default_lang(m)
    langs = doc_langs(m)
    opts = (hdr.get("exportOptions") or {}).get("jsonschema") or {}
    closed = opts.get("closed", True)

    def dn(n):
        return tname(element(m, n), n, "json")

    def doc(e):
        d = {}
        if e.get("label"):
            d["title"] = text(m, e["label"], L)
        if e.get("description"):
            d["description"] = text(m, e["description"], L)
        if len(langs) > 1:
            i18n = {}
            for lg in langs:
                if lg == L:
                    continue
                t = {}
                lab, des = texts(m, e.get("label")).get(lg), texts(m, e.get("description")).get(lg)
                if lab:
                    t["title"] = lab
                if des:
                    t["description"] = des
                if t:
                    i18n[lg] = t
            if i18n:
                d["x-i18n"] = i18n
        return d

    def value_schema(a):
        t = a["type"]
        if t in m["enumerations"] or t in m["datatypes"]:
            return {"$ref": f"#/$defs/{dn(t)}"}
        c = a.get("constraints") or {}
        if t == "geometry":
            gt = c.get("geometryType")
            return {"$ref": f"https://geojson.org/schema/{gt}.json"} if gt and gt != "Geometry" else dict(JSON_TYPES[t])
        s = dict(JSON_TYPES[t])
        for src, dst in (("maxLength", "maxLength"), ("minLength", "minLength"), ("pattern", "pattern"),
                         ("min", "minimum"), ("max", "maximum")):
            if src in c:
                s[dst] = c[src]
        if c.get("unit"):
            s["$comment"] = f"unit: {c['unit']}"
        return s

    def prop(a):
        lo, hi = mult(a.get("multiplicity"))
        s = value_schema(a)
        if a.get("voidable"):
            s = {"anyOf": [s, {"type": "null"}]}
        if hi > 1:
            s = {"type": "array", "items": s, **({"minItems": lo} if lo else {}), **({"maxItems": hi} if hi != INF else {})}
        s = {**doc(a), **s}
        if a.get("deprecated"):
            s["deprecated"] = True
        if a.get("derived"):
            s["readOnly"] = True
        # voidable = present but may be nil (XSD nillable), so it stays required
        return s, lo >= 1 and not a.get("derived")

    def ref_schema(target):
        ide = identifier(m, target)
        s = value_schema(all_attrs(m, target)[ide["attribute"]]) if ide else {"type": "string"}
        return {"description": f"Reference to {target} by identifier", **s}

    defs = {}
    for n, e in m["enumerations"].items():
        codes = codes_of(e)
        typ = "integer" if e.get("codeType") == "integer" else "string"
        d = doc(e)
        if e.get("extensible"):
            d.update({"type": typ, "examples": codes, "$comment": "extensible code list; known values in examples"})
        else:
            d.update({"type": typ, "enum": codes})
        labels = {}
        for v in values_of(e):
            for lg, t in texts(m, v.get("label")).items():
                labels.setdefault(lg, {})[str(v.get("code"))] = t
        if labels:
            d["x-enumLabels"] = labels
        if e.get("deprecated"):
            d["deprecated"] = True
        defs[dn(n)] = d
    for n, e in m["datatypes"].items():
        props, req = {}, []
        for an, a in attrs_of(e).items():
            pn = tname(a, an, "json")
            props[pn], r = prop(a)
            if r:
                req.append(pn)
        d = {**doc(e), "type": "object", "properties": props}
        if req:
            d["required"] = req
        if closed:
            d["additionalProperties"] = False
        defs[dn(n)] = d
    for n, e in m["classes"].items():
        props, req = {}, []
        for an, a in attrs_of(e).items():
            pn = tname(a, an, "json")
            props[pn], r = prop(a)
            if r:
                req.append(pn)
        for a in m["associations"]:
            for owner_end, other_end, forward in (("from", "to", True), ("to", "from", False)):
                if a[owner_end]["class"] != n:
                    continue
                if not forward and (a.get("navigable", "from") != "both" or a.get("kind") == "composition"):
                    continue
                end = a[other_end]
                if not end.get("role"):
                    continue
                role = tname(end, end["role"], "json")
                target = end["class"]
                lo, hi = mult(end.get("multiplicity"))
                item = {"$ref": f"#/$defs/{dn(target)}"} if (a.get("kind") == "composition" and forward) \
                    else ref_schema(target)
                s = item if hi == 1 else {"type": "array", "items": item,
                                          **({"minItems": lo} if lo else {}),
                                          **({"maxItems": hi} if hi != INF else {})}
                s = {**doc(a), **s}
                if a.get("deprecated"):
                    s["deprecated"] = True
                props[role] = s
                if lo >= 1:
                    req.append(role)
        hist = e.get("history") or {}
        if hist.get("mode") in ("versioned", "bitemporal") and not e.get("extends"):
            props["versionId"] = {"type": "string", "description": "Version of this object"}
            if hist.get("validTime", True):
                props["validFrom"] = {"type": "string", "format": "date-time"}
                props["validTo"] = {"anyOf": [{"type": "string", "format": "date-time"}, {"type": "null"}]}
            if hist.get("mode") == "bitemporal" or hist.get("transactionTime"):
                props["recordedAt"] = {"type": "string", "format": "date-time"}
        d = {**doc(e), "type": "object", "properties": props}
        if req:
            d["required"] = req
        if e.get("extends"):
            d = {"allOf": [{"$ref": f"#/$defs/{dn(e['extends'])}"}], **d}
        has_children = any(c.get("extends") == n for c in m["classes"].values())
        if closed and not has_children:
            d["unevaluatedProperties"] = False
        if e.get("deprecated"):
            d["deprecated"] = True
        cons = [c for c in m["constraints"] if c.get("appliesTo") == n]
        if cons:
            d["$comment"] = "; ".join(f"{c.get('id')}: {text(m, c.get('description'), L)}" for c in cons)
        defs[dn(n)] = d
    root = opts.get("root")
    schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": f"{hdr.get('namespace', '').rstrip('/')}/{hdr.get('version')}/schema.json",
        "title": text(m, hdr.get("title"), L) or hdr.get("name"),
        "description": text(m, hdr.get("description"), L),
    }
    if root:
        schema["$ref"] = f"#/$defs/{dn(root)}"
    else:
        roots = [n for n, e in m["classes"].items() if not e.get("abstract") and not is_part(m, n)]
        schema["anyOf"] = [{"$ref": f"#/$defs/{dn(n)}"} for n in roots]
    schema["$defs"] = defs
    return json.dumps(schema, indent=2, ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------- XSD

XSD_TYPES = {"string": "xs:string", "text": "xs:string", "boolean": "xs:boolean", "integer": "xs:int",
             "long": "xs:long", "decimal": "xs:decimal", "float": "xs:double", "date": "xs:date",
             "dateTime": "xs:dateTime", "time": "xs:time", "duration": "xs:duration", "uri": "xs:anyURI",
             "binary": "xs:base64Binary", "geometry": "xs:anyType"}
FACETS = (("maxLength", "maxLength"), ("minLength", "minLength"), ("pattern", "pattern"),
          ("min", "minInclusive"), ("max", "maxInclusive"), ("precision", "totalDigits"), ("scale", "fractionDigits"))


def export_xsd(m, lang=None):
    hdr = m["model"]
    ns = hdr.get("namespace", "urn:example")
    p = hdr.get("prefix", "m")
    langs = doc_langs(m)

    def q(s):
        return xml_escape(str(s), {'"': "&quot;"})

    def type_name(n):
        e = element(m, n)
        return (e.get("xml") or {}).get("typeName") or tname(e, n, "xsd") + "Type"

    def annotation(v, ind, before="", after=""):
        tx = texts(m, v)
        if not tx and (before or after):
            tx = {langs[0]: ""}
        if not tx:
            return []
        out = [f"{ind}<xs:annotation>"]
        for lg in langs + [x for x in tx if x not in langs]:
            if lg in tx:
                body = " ".join(x for x in (before, tx[lg], after) if x)
                out.append(f'{ind}  <xs:documentation xml:lang="{q(lg)}">{xml_escape(body)}</xs:documentation>')
        out.append(f"{ind}</xs:annotation>")
        return out

    def simple_type(a):
        """(type name, facets) for a simple-valued attribute."""
        t = a["type"]
        x = a.get("xml") or {}
        if x.get("type"):
            return x["type"], []
        if t in m["enumerations"] or t in m["datatypes"]:
            return f"{p}:{type_name(t)}", []
        typ = f"{p}:UUIDType" if t == "uuid" else XSD_TYPES[t]
        c = a.get("constraints") or {}
        facets = [] if t == "geometry" else \
            [f'<xs:{f} value="{q(c[k])}"/>' for k, f in FACETS if k in c]
        return typ, facets

    def notes(a):
        c = a.get("constraints") or {}
        before = "DEPRECATED." if a.get("deprecated") else ""
        after = ""
        if a["type"] == "geometry":
            after = (f"Geometry {c.get('geometryType', '')} in {c.get('crs', '?')} — "
                     "replace xs:anyType by a GML property type.")
        return before, after

    def element_decl(name, a, ind):
        lo, hi = mult(a.get("multiplicity"))
        occ = f' minOccurs="{lo}"' + (f' maxOccurs="{"unbounded" if hi == INF else hi}"' if hi != 1 else "")
        nil = ' nillable="true"' if a.get("voidable") else ""
        typ, facets = simple_type(a)
        before, after = notes(a)
        ann = annotation(a.get("description"), ind + "  ", before, after)
        if facets:
            return ([f'{ind}<xs:element name="{name}"{occ}{nil}>'] + ann +
                    [f"{ind}  <xs:simpleType>", f'{ind}    <xs:restriction base="{typ}">'] +
                    [f"{ind}      {x}" for x in facets] +
                    [f"{ind}    </xs:restriction>", f"{ind}  </xs:simpleType>", f"{ind}</xs:element>"])
        if ann:
            return [f'{ind}<xs:element name="{name}" type="{typ}"{occ}{nil}>'] + ann + [f"{ind}</xs:element>"]
        return [f'{ind}<xs:element name="{name}" type="{typ}"{occ}{nil}/>']

    def attribute_decl(name, a, ind):
        lo, _ = mult(a.get("multiplicity"))
        use = ' use="required"' if lo >= 1 else ""
        typ, facets = simple_type(a)
        ann = annotation(a.get("description"), ind + "  ", *notes(a))
        if facets:
            return ([f'{ind}<xs:attribute name="{name}"{use}>'] + ann +
                    [f"{ind}  <xs:simpleType>", f'{ind}    <xs:restriction base="{typ}">'] +
                    [f"{ind}      {x}" for x in facets] +
                    [f"{ind}    </xs:restriction>", f"{ind}  </xs:simpleType>", f"{ind}</xs:attribute>"])
        if ann:
            return [f'{ind}<xs:attribute name="{name}" type="{typ}"{use}>'] + ann + [f"{ind}</xs:attribute>"]
        return [f'{ind}<xs:attribute name="{name}" type="{typ}"{use}/>']

    def members(n, e, ind):
        """(element lines, attribute lines) for a class or datatype."""
        els, ats = [], []
        for an, a in attrs_of(e).items():
            name = tname(a, an, "xsd")
            if (a.get("xml") or {}).get("attribute"):
                ats += attribute_decl(name, a, ind)
            else:
                els += element_decl(name, a, ind)
        if n in m["classes"]:
            for a in m["associations"]:
                for owner_end, other_end, forward in (("from", "to", True), ("to", "from", False)):
                    if a[owner_end]["class"] != n:
                        continue
                    if not forward and (a.get("navigable", "from") != "both" or a.get("kind") == "composition"):
                        continue
                    end = a[other_end]
                    if not end.get("role"):
                        continue
                    lo, hi = mult(end.get("multiplicity"))
                    typ = f'{p}:{type_name(end["class"])}' if (a.get("kind") == "composition" and forward) \
                        else f"{p}:ReferenceType"
                    occ = f' minOccurs="{lo}"' + (f' maxOccurs="{"unbounded" if hi == INF else hi}"' if hi != 1 else "")
                    els.append(f'{ind}<xs:element name="{tname(end, end["role"], "xsd")}" type="{typ}"{occ}/>')
        return els, ats

    L = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:{p}="{q(ns)}"',
         f'           targetNamespace="{q(ns)}" elementFormDefault="qualified" version="{q(hdr.get("version"))}">']
    L += annotation(hdr.get("description"), "  ")
    L += ['  <xs:simpleType name="UUIDType">',
          '    <xs:restriction base="xs:string"><xs:pattern value="[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"/></xs:restriction>',
          '  </xs:simpleType>',
          '  <xs:complexType name="ReferenceType">',
          '    <xs:annotation><xs:documentation xml:lang="en">Reference to another object by identifier or URI.</xs:documentation></xs:annotation>',
          '    <xs:attribute name="href" type="xs:string" use="required"/>',
          '  </xs:complexType>']
    for n, e in m["enumerations"].items():
        base = "xs:int" if e.get("codeType") == "integer" else "xs:string"
        L.append(f'  <xs:simpleType name="{type_name(n)}">')
        if e.get("extensible"):
            known = ", ".join(str(c) for c in codes_of(e))
            L += annotation(e.get("description"), "    ", after=f"Extensible code list. Known values: {known}")
            L += [f'    <xs:restriction base="{base}"/>', "  </xs:simpleType>"]
            continue
        L += annotation(e.get("description"), "    ")
        L.append(f'    <xs:restriction base="{base}">')
        for v in values_of(e):
            vann = annotation(v.get("label") or v.get("description"), "        ")
            if vann:
                L += [f'      <xs:enumeration value="{q(v.get("code"))}">'] + vann + ["      </xs:enumeration>"]
            else:
                L.append(f'      <xs:enumeration value="{q(v.get("code"))}"/>')
        L += ["    </xs:restriction>", "  </xs:simpleType>"]
    for n, e in m["datatypes"].items():
        L.append(f'  <xs:complexType name="{type_name(n)}">')
        L += annotation(e.get("description"), "    ")
        els, ats = members(n, e, "      ")
        L += ["    <xs:sequence>"] + els + ["    </xs:sequence>"] + [x[2:] for x in ats]
        L.append("  </xs:complexType>")
    for n, e in m["classes"].items():
        abstract = ' abstract="true"' if e.get("abstract") else ""
        L.append(f'  <xs:complexType name="{type_name(n)}"{abstract}>')
        cons = [c for c in m["constraints"] if c.get("appliesTo") == n]
        after = ("Constraints: " + "; ".join(f"{c.get('id')}: {text(m, c.get('description'))}" for c in cons)) if cons else ""
        L += annotation(e.get("description"), "    ", after=after)
        if e.get("extends"):
            els, ats = members(n, e, "          ")
            L += ["    <xs:complexContent>", f'      <xs:extension base="{p}:{type_name(e["extends"])}">',
                  "        <xs:sequence>"] + els + ["        </xs:sequence>"] + [x[2:] for x in ats]
            L += ["      </xs:extension>", "    </xs:complexContent>"]
        else:
            els, ats = members(n, e, "      ")
            L += ["    <xs:sequence>"] + els + ["    </xs:sequence>"] + [x[2:] for x in ats]
        L.append("  </xs:complexType>")
        glob = (e.get("xml") or {}).get("globalElement")
        if glob is None:
            glob = not e.get("abstract") and not is_part(m, n)
        if glob:
            par = e.get("extends")
            sub = f' substitutionGroup="{p}:{tname(m["classes"][par], par, "xsd")}"' \
                if par and not m["classes"][par].get("abstract") else ""
            L.append(f'  <xs:element name="{tname(e, n, "xsd")}" type="{p}:{type_name(n)}"{sub}/>')
    L.append("</xs:schema>")
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------- PostgreSQL

def _pg_type(a):
    t = a["type"]
    c = a.get("constraints") or {}
    if t == "string":
        return f"varchar({c['maxLength']})" if c.get("maxLength") else "text"
    if t == "decimal":
        return f"numeric({c['precision']},{c.get('scale', 0)})" if c.get("precision") else "numeric"
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


def export_postgres(m, lang=None):
    hdr = m["model"]
    L_ = lang or default_lang(m)
    sch = snake(hdr.get("name", "model"))
    out, fks, idx, comments, tables = [], [], [], [], {}
    uses_geom = any(a.get("type") == "geometry" for k in ("classes", "datatypes") for e in m[k].values()
                    for a in attrs_of(e).values())
    out.append(f"-- Generated by dmtool from {hdr.get('name')} {hdr.get('version')} (comments: {L_}). Do not edit; regenerate.")
    out.append("CREATE EXTENSION IF NOT EXISTS pgcrypto;")
    if uses_geom:
        out.append("CREATE EXTENSION IF NOT EXISTS postgis;")
    out.append(f"CREATE SCHEMA IF NOT EXISTS {sch};\n")

    def comment(kind, obj, v):
        t = text(m, v, L_)
        if t:
            comments.append(f"COMMENT ON {kind} {obj} IS {_qlit(t)};")

    enum_sql = {}  # name -> (kind, sql name or None, codes)
    for n, e in m["enumerations"].items():
        codes = codes_of(e)
        integer = e.get("codeType") == "integer"
        tn = f"{sch}.{_pgname(e, n)}"
        if e.get("extensible"):
            out.append(f"CREATE TABLE {tn} (\n  code {'integer' if integer else 'text'} PRIMARY KEY,\n"
                       f"  label text,\n  description text,\n  deprecated boolean NOT NULL DEFAULT false\n);")
            rows = [f"({c if integer else _qlit(c)}, {_qlit(text(m, v.get('label'), L_)) if v.get('label') else 'NULL'})"
                    for c, v in zip(codes, values_of(e))]
            if rows:
                out.append(f"INSERT INTO {tn} (code, label) VALUES " + ", ".join(rows) + ";")
            enum_sql[n] = ("table", tn, codes)
            comment("TABLE", tn, e.get("description"))
        elif integer:
            enum_sql[n] = ("int", None, codes)
        else:
            out.append(f"CREATE TYPE {tn} AS ENUM ({', '.join(_qlit(c) for c in codes)});")
            enum_sql[n] = ("type", tn, codes)
            labels = "; ".join(f"{v.get('code')} = {text(m, v.get('label'), L_)}" for v in values_of(e) if v.get("label"))
            desc = " ".join(x for x in (text(m, e.get("description"), L_), labels) if x)
            if desc:
                comments.append(f"COMMENT ON TYPE {tn} IS {_qlit(desc)};")
    out.append("")

    def col_type(a):
        t = a["type"]
        if t in enum_sql:
            kind, tn, _ = enum_sql[t]
            if kind == "type":
                return tn
            return "integer" if m["enumerations"][t].get("codeType") == "integer" else "text"
        return _pg_type(a)

    def col_check(cn, a):
        t = a["type"]
        if t in enum_sql and enum_sql[t][0] == "int":
            return f" CHECK ({cn} IN ({', '.join(str(c) for c in enum_sql[t][2])}))"
        return ""

    def pk_info(cname):
        ide = identifier(m, cname)
        if ide:
            a = all_attrs(m, cname)[ide["attribute"]]
            return _pgname(a, ide["attribute"]), col_type(a), ide
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
                owner_pk, owner_type, _ = pk_info(cname) if cname in m["classes"] else ("id", "bigint", None)
                ct = f"{table}_{cn}"
                owner_col = f"{snake(root_class(m, cname)) if cname in m['classes'] else 'owner'}_{owner_pk}"
                ccols = [f"  {owner_col} {owner_type} NOT NULL", "  ord integer NOT NULL"]
                if t in m["datatypes"]:
                    ccols += [c for c, _ in column_defs(ct, t, attrs_of(m["datatypes"][t]))]
                else:
                    ccols.append(f"  value {col_type(a)} NOT NULL{col_check('value', a)}")
                ccols.append(f"  PRIMARY KEY ({owner_col}, ord)")
                out.append(f"CREATE TABLE {ct} (\n" + ",\n".join(ccols) + "\n);")
                fks.append(f"ALTER TABLE {ct} ADD FOREIGN KEY ({owner_col}) REFERENCES {table} ({owner_pk}) ON DELETE CASCADE;")
                comment("TABLE", ct, a.get("description"))
                continue
            if t in m["datatypes"]:
                cols += column_defs(table, t, attrs_of(m["datatypes"][t]), prefix=cn + "_",
                                    parent_required=required and parent_required)
                continue
            uniq = " UNIQUE" if a.get("unique") else ""
            cols.append((f"  {cn} {col_type(a)}{notnull}{uniq}{col_check(cn, a)}", (cn, a.get("description"))))
        return cols

    for n, e in m["classes"].items():
        tables[n] = f"{sch}.{_pgname(e, n)}"
    for n, e in m["classes"].items():
        tn = tables[n]
        pk_col, pk_type, ide = pk_info(n)
        cols = []
        own = dict(attrs_of(e))
        if e.get("extends"):
            cols.append((f"  {pk_col} {pk_type} PRIMARY KEY", (pk_col, None)))
            fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({pk_col}) REFERENCES {tables[e['extends']]} ({pk_col}) ON DELETE CASCADE;")
            own.pop(ide["attribute"] if ide else "", None)
        elif ide:
            a = own.pop(ide["attribute"])
            default = " DEFAULT gen_random_uuid()" if ide.get("strategy") == "uuid" and a["type"] == "uuid" else ""
            if ide.get("strategy") == "sequence" and a["type"] in ("integer", "long"):
                default = " GENERATED ALWAYS AS IDENTITY"
            cols.append((f"  {pk_col} {pk_type}{default} PRIMARY KEY", (pk_col, a.get("description"))))
        else:
            cols.append(("  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY", ("id", "Surrogate key")))
        cols += column_defs(tn, n, own)
        for an, a in own.items():
            t = a.get("type")
            if t in enum_sql and enum_sql[t][0] == "table" and mult(a.get("multiplicity"))[1] == 1:
                fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({_pgname(a, an)}) REFERENCES {enum_sql[t][1]} (code);")
        hist = e.get("history") or {}
        if not e.get("extends"):
            if hist.get("validTime"):
                cols.append(("  valid_from timestamptz NOT NULL DEFAULT now()", ("valid_from", "Start of validity (valid time)")))
                cols.append(("  valid_to timestamptz", ("valid_to", "End of validity (valid time); NULL = open")))
            if hist.get("deletion") == "logical":
                cols.append(("  deleted_at timestamptz", ("deleted_at", "Logical deletion timestamp")))
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
                col = f"{_pgname(t, t.get('role') or tgt)}_{tpk}"
                nn = " NOT NULL" if tm[0] >= 1 else ""
                cols.append((f"  {col} {ttype}{nn}", (col, a.get("description"))))
                fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({col}) REFERENCES {tables[tgt]} ({tpk});")
                idx.append(f"CREATE INDEX ON {tn} ({col});")
            elif not comp and t["class"] == n and fm[1] == 1 and tm[1] > 1:
                src = f["class"]
                spk, stype, _ = pk_info(src)
                col = f"{_pgname(f, f.get('role') or src)}_{spk}"
                nn = " NOT NULL" if fm[0] >= 1 else ""
                cols.append((f"  {col} {stype}{nn}", (col, a.get("description"))))
                fks.append(f"ALTER TABLE {tn} ADD FOREIGN KEY ({col}) REFERENCES {tables[src]} ({spk});")
                idx.append(f"CREATE INDEX ON {tn} ({col});")
        out.append(f"CREATE TABLE {tn} (\n" + ",\n".join(c for c, _ in cols) + "\n);")
        comment("TABLE", tn, e.get("description"))
        for _, (cn, d) in cols:
            comment("COLUMN", f"{tn}.{cn}", d)
        if not e.get("extends") and hist.get("mode") in ("audit", "versioned", "bitemporal"):
            out.append(f"CREATE TABLE {tn}_history (\n  history_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n"
                       f"  operation char(1) NOT NULL CHECK (operation IN ('I','U','D')),\n"
                       f"  recorded_at timestamptz NOT NULL DEFAULT now(),\n  recorded_by text,\n"
                       f"  row_data jsonb NOT NULL\n);")
            idx.append(f"CREATE INDEX ON {tn}_history ((row_data->>{_qlit(pk_col)}), recorded_at);")
            note = f"History ({hist.get('mode')}) of {n}; fill via trigger on {tn}."
            comments.append(f"COMMENT ON TABLE {tn}_history IS {_qlit(note)};")
    for a in m["associations"]:
        f, t = a["from"], a["to"]
        fm, tm = mult(f.get("multiplicity")), mult(t.get("multiplicity"))
        if a.get("kind") != "composition" and fm[1] > 1 and tm[1] > 1:
            fpk, ftype, _ = pk_info(f["class"])
            tpk, ttype, _ = pk_info(t["class"])
            jt = f"{sch}.{snake(f['class'])}_{_pgname(t, t.get('role') or t['class'])}"
            fc, tc = f"{snake(f['class'])}_{fpk}", f"{snake(t['class'])}_{tpk}"
            if fc == tc:
                tc = f"{snake(t.get('role') or 'target')}_{tpk}"
            out.append(f"CREATE TABLE {jt} (\n  {fc} {ftype} NOT NULL,\n  {tc} {ttype} NOT NULL,\n  PRIMARY KEY ({fc}, {tc})\n);")
            fks.append(f"ALTER TABLE {jt} ADD FOREIGN KEY ({fc}) REFERENCES {tables[f['class']]} ({fpk}) ON DELETE CASCADE;")
            fks.append(f"ALTER TABLE {jt} ADD FOREIGN KEY ({tc}) REFERENCES {tables[t['class']]} ({tpk}) ON DELETE CASCADE;")
            idx.append(f"CREATE INDEX ON {jt} ({tc});")
    for c in m["constraints"]:
        out.append(f"-- Constraint {c.get('id')} on {c.get('appliesTo')} ({c.get('enforcement', 'enforced')}, "
                   f"scope {c.get('scope', 'all')}): {text(m, c.get('description'), L_)} "
                   f"(not generated; implement as CHECK/trigger if required)")
    out.append("")
    out += fks + [""] + idx + [""] + comments
    return "\n".join(out) + "\n"


EXPORTERS = {"jsonschema": export_jsonschema, "xsd": export_xsd, "postgres": export_postgres}


# --------------------------------------------------------------------------- diff

WIDENING = {("integer", "long"), ("integer", "decimal"), ("long", "decimal"), ("integer", "float"),
            ("string", "text"), ("date", "dateTime")}
LEVEL = {"patch": 0, "minor": 1, "major": 2}


def consumer_mode(m, override=None):
    """'strict' when consumers validate against the released schema with closed content, else 'tolerant'."""
    if override:
        return override
    hdr = m["model"]
    explicit = (hdr.get("compatibility") or {}).get("consumers")
    if explicit:
        return explicit
    purposes = set(hdr.get("purposes") or [])
    if not purposes & {"exchange", "api"}:
        return "tolerant"
    closed_json = ((hdr.get("exportOptions") or {}).get("jsonschema") or {}).get("closed", True)
    return "strict" if closed_json or "xsd" in (hdr.get("targets") or []) else "tolerant"


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
        changes.append(("risk", path, s + " (now optional: consumers may expect the value)"))
    else:
        changes.append(("risk", path, s + " (upper bound raised)"))


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
        changes.append(("risk", path, msg + " (relaxed)") if relaxed
                       else ("major", path, msg + " (tightened: existing data may violate it)"))


def _cmp_serialisation(path, o, n, changes):
    for key, what in (("names", "export name"), ("xml", "XML representation")):
        if (o.get(key) or {}) != (n.get(key) or {}):
            changes.append(("major", path, f"{what} changed {o.get(key) or {}} → {n.get(key) or {}} "
                                           "(the wire format changes for that target)"))
    if o.get("label") != n.get("label"):
        changes.append(("patch", path, "label changed"))
    if o.get("description") != n.get("description"):
        changes.append(("patch", path, "description changed"))


def _cmp_attr(path, o, n, changes):
    if o.get("type") != n.get("type"):
        pair = (o.get("type"), n.get("type"))
        if pair in WIDENING:
            changes.append(("risk", path, f"type widened {pair[0]} → {pair[1]}"))
        else:
            changes.append(("major", path, f"type changed {pair[0]} → {pair[1]}"))
    _cmp_mult(path, o.get("multiplicity"), n.get("multiplicity"), changes)
    _cmp_constraints(path, o.get("constraints"), n.get("constraints"), changes)
    if bool(o.get("voidable")) != bool(n.get("voidable")):
        changes.append(("risk", path, "now voidable") if n.get("voidable")
                       else ("major", path, "no longer voidable: existing nil values become invalid"))
    if bool(o.get("unique")) != bool(n.get("unique")):
        changes.append(("major", path, "unique added: existing duplicates become invalid") if n.get("unique")
                       else ("minor", path, "unique removed"))
    if bool(o.get("derived")) != bool(n.get("derived")):
        changes.append(("major", path, f"derived {o.get('derived', False)} → {n.get('derived', False)}"))
    if not _deprecated(o) and _deprecated(n):
        changes.append(("minor", path, "deprecated"))
    _cmp_serialisation(path, o, n, changes)


def _cmp_attr_sets(owner, oa, na, changes):
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
            changes.append(("risk", f"{owner}.{an}", "optional attribute added"))
    removed = [an for an in oa if an not in na]
    for r in removed:
        for ad in added:
            if oa[r].get("type") == na[ad].get("type"):
                changes.append(("patch", f"{owner}.{ad}", f"hint: may be a rename of '{r}' — prefer add + deprecate"))
    for an in oa:
        if an in na:
            _cmp_attr(f"{owner}.{an}", oa[an], na[an], changes)


def _constraint_soft(c):
    return c.get("enforcement") in ("warning", "documented") or c.get("scope") == "new"


def diff(mo, mn, consumers=None):
    """List of (level, element, change, tag); level patch|minor|major, tag doc|compatible|breaking|consumer-breaking."""
    raw = []
    for kind in ("enumerations", "datatypes", "classes"):
        label = {"enumerations": "enumeration", "datatypes": "datatype", "classes": "class"}[kind]
        for n in mo[kind]:
            if n not in mn[kind]:
                raw.append(("major", n, f"{label} removed" + (" (was deprecated)" if _deprecated(mo[kind][n]) else "")))
        for n in mn[kind]:
            if n not in mo[kind]:
                raw.append(("minor", n, f"{label} added"))
    for n, e in mo["enumerations"].items():
        if n not in mn["enumerations"]:
            continue
        ne = mn["enumerations"][n]
        oc = {v.get("code"): v for v in values_of(e)}
        nc = {v.get("code"): v for v in values_of(ne)}
        for c in oc:
            if c not in nc:
                raw.append(("major", f"{n}.{c}", "enum value removed (deprecate instead)"))
            else:
                if not _deprecated(oc[c]) and _deprecated(nc[c]):
                    raw.append(("minor", f"{n}.{c}", "enum value deprecated"))
                if oc[c].get("label") != nc[c].get("label") or oc[c].get("description") != nc[c].get("description"):
                    raw.append(("patch", f"{n}.{c}", "enum value label/description changed"))
        for c in nc:
            if c not in oc:
                raw.append(("minor", f"{n}.{c}", "enum value added (extensible list)") if ne.get("extensible")
                           else ("risk", f"{n}.{c}", "enum value added to a closed enumeration"))
        if bool(e.get("extensible")) != bool(ne.get("extensible")):
            raw.append(("minor", n, "enumeration made extensible") if ne.get("extensible")
                       else ("major", n, "enumeration closed: values outside the list become invalid"))
        if e.get("codeType", "string") != ne.get("codeType", "string"):
            raw.append(("major", n, f"codeType {e.get('codeType', 'string')} → {ne.get('codeType', 'string')}"))
        _cmp_serialisation(n, e, ne, raw)
    for n, e in mo["datatypes"].items():
        if n in mn["datatypes"]:
            _cmp_serialisation(n, e, mn["datatypes"][n], raw)
            _cmp_attr_sets(n, attrs_of(e), attrs_of(mn["datatypes"][n]), raw)
    for n, e in mo["classes"].items():
        if n not in mn["classes"]:
            continue
        ne = mn["classes"][n]
        if e.get("extends") != ne.get("extends"):
            raw.append(("major", n, f"extends {e.get('extends')} → {ne.get('extends')}"))
        if bool(e.get("abstract")) != bool(ne.get("abstract")):
            raw.append(("major" if ne.get("abstract") else "minor", n,
                        "made abstract" if ne.get("abstract") else "no longer abstract"))
        if (e.get("identifier") or {}) != (ne.get("identifier") or {}):
            raw.append(("major", n, f"identifier {e.get('identifier')} → {ne.get('identifier')}"))
        if (e.get("history") or {}) != (ne.get("history") or {}):
            raw.append(("major", n, f"history {e.get('history')} → {ne.get('history')} "
                                    "(data historisation changes need a migration; review)"))
        if not _deprecated(e) and _deprecated(ne):
            raw.append(("minor", n, "class deprecated"))
        if (e.get("nfr") or {}) != (ne.get("nfr") or {}):
            raw.append(("patch", n, "non-functional requirements changed (check physical design)"))
        _cmp_serialisation(n, e, ne, raw)
        _cmp_attr_sets(n, attrs_of(e), attrs_of(ne), raw)

    def akey(a):
        return a.get("name") or f"{a['from']['class']}.{a['to'].get('role')}"
    oa = {akey(a): a for a in mo["associations"]}
    na = {akey(a): a for a in mn["associations"]}
    for k in oa:
        if k not in na:
            raw.append(("major", k, "association removed"))
    for k, a in na.items():
        if k not in oa:
            lo_to = (mult(a["to"].get("multiplicity")) or (1, 1))[0]
            lo_from = (mult(a["from"].get("multiplicity")) or (0, 0))[0] if a.get("navigable") == "both" else 0
            if lo_to >= 1 or lo_from >= 1:
                raw.append(("major", k, "mandatory association added: existing objects lack the link"))
            else:
                raw.append(("risk", k, "optional association added"))
            continue
        o = oa[k]
        if o.get("kind", "reference") != a.get("kind", "reference"):
            raw.append(("major", k, f"kind {o.get('kind', 'reference')} → {a.get('kind', 'reference')}"))
        for end in ("from", "to"):
            if o[end]["class"] != a[end]["class"]:
                raw.append(("major", f"{k}.{end}", f"class {o[end]['class']} → {a[end]['class']}"))
            if o[end].get("role") != a[end].get("role"):
                raw.append(("major", f"{k}.{end}", f"role renamed {o[end].get('role')} → {a[end].get('role')}"))
            if (o[end].get("names") or {}) != (a[end].get("names") or {}):
                raw.append(("major", f"{k}.{end}", "export name of role changed (wire format changes)"))
            _cmp_mult(f"{k}.{end}", o[end].get("multiplicity"), a[end].get("multiplicity"), raw)
        if not _deprecated(o) and _deprecated(a):
            raw.append(("minor", k, "association deprecated"))
    oc = {c.get("id"): c for c in mo["constraints"]}
    nc = {c.get("id"): c for c in mn["constraints"]}
    for cid, c in nc.items():
        if cid not in oc:
            raw.append(("minor", f"constraint {cid}", "constraint added (not enforced or new data only)") if _constraint_soft(c)
                       else ("major", f"constraint {cid}", "constraint added: existing data may violate it "
                                                           "(use scope: new or enforcement: warning if it only targets new data)"))
            continue
        o = oc[cid]
        changed = o.get("expression") != c.get("expression") or \
            o.get("enforcement", "enforced") != c.get("enforcement", "enforced") or \
            o.get("scope", "all") != c.get("scope", "all")
        if changed:
            raw.append(("minor", f"constraint {cid}", "constraint changed (not enforced or new data only)") if _constraint_soft(c)
                       else ("major", f"constraint {cid}", "constraint changed or now enforced — review whether it is tightened"))
        elif o.get("description") != c.get("description"):
            raw.append(("patch", f"constraint {cid}", "description changed"))
    for cid in oc:
        if cid not in nc:
            raw.append(("risk", f"constraint {cid}", "constraint removed"))
    if mo["model"].get("namespace") != mn["model"].get("namespace"):
        raw.append(("major", "model.namespace", "namespace changed"))
    if (mo["model"].get("languages") or {}) != (mn["model"].get("languages") or {}):
        raw.append(("patch", "model.languages", "documentation languages changed"))

    mode = consumer_mode(mo, consumers)
    projection = bool((mo["model"].get("compatibility") or {}).get("projection"))
    out = []
    for lvl, path, msg in raw:
        if lvl == "risk":
            if mode == "strict" and projection:
                out.append(("minor", path, msg + " — strict consumers of older versions must get the projection without it",
                            "consumer-breaking"))
            elif mode == "strict":
                out.append(("major", path, msg + " — breaks consumers that validate strictly against the released schema",
                            "consumer-breaking"))
            else:
                out.append(("minor", path, msg + " (RISK: consumers relying on the old shape)", "compatible"))
        else:
            out.append((lvl, path, msg, {"major": "breaking", "minor": "compatible", "patch": "doc"}[lvl]))
    return out


def recommend(old_version, new_version, changes):
    level = max((LEVEL[c[0]] for c in changes), default=-1)
    ov = semver(old_version)
    if not ov:
        return None, None, level
    ma, mi, pa = ov
    if level == 2:
        rec = f"{ma + 1}.0.0" if ma >= 1 else f"0.{mi + 1}.0"
    elif level == 1:
        rec = f"{ma}.{mi + 1}.0"
    elif level == 0:
        rec = f"{ma}.{mi}.{pa + 1}"
    else:
        rec = str(old_version)
    nv = semver(new_version)
    ok = None if nv is None else nv >= semver(rec)
    return rec, ok, level


def print_diff(changes, ov, nv, mode):
    order = {"major": 0, "minor": 1, "patch": 2}
    tags = {"breaking": "BREAKING", "consumer-breaking": "CONSUMERS", "compatible": "compatible", "doc": "doc"}
    print(f"Model diff {ov} → {nv}: {len(changes)} change(s); consumers: {mode}\n")
    for lvl, p, c, tag in sorted(changes, key=lambda x: (order[x[0]], x[1])):
        print(f"  [{tags[tag]:10}] {p}: {c}")
    print()


# --------------------------------------------------------------------------- init and release

INIT_FILES = {
    "sources.md": "# Sources\n\n| ID | Title | Location | Version/date | Kind | Covers | Authority |\n"
                  "|----|-------|----------|--------------|------|--------|-----------|\n",
    "decisions.md": "# Decisions\n\n<!-- ## D-001 Title (YYYY-MM-DD)\nContext … Options … Choice … Rationale … -->\n",
    "open-questions.md": "# Open questions and assumptions\n\n## Questions\n\n<!-- Q-001 … (blocking? owner?) -->\n\n"
                         "## Assumptions\n\n<!-- A-001 … (confirmed: no) -->\n",
    "glossary.md": "# Glossary\n\n| Term | Language | Definition | Synonyms | Do not use |\n"
                   "|------|----------|------------|----------|------------|\n",
    "CHANGELOG.md": "# Changelog\n",
}


def init_workspace(d, name, namespace, languages):
    d = Path(d)
    if (d / "model.yaml").exists():
        sys.exit(f"{d / 'model.yaml'} already exists — not overwriting")
    langs = [x.strip() for x in languages.split(",") if x.strip()] or ["en"]
    kebab = snake(name).replace("_", "-")
    model = (
        "# Canonical, implementation-neutral data model. Format: references/model-format.md\n"
        "# Check with: dmtool.py validate model.yaml\n\n"
        "model:\n"
        f"  name: {name}\n"
        f"  title: {name}\n"
        "  description: null\n"
        f"  namespace: {namespace or f'https://example.org/models/{kebab}'}\n"
        f"  prefix: {kebab[:3] or 'm'}\n"
        "  version: 0.1.0\n"
        "  status: draft\n"
        "  purposes: []          # persistence | exchange | api | analytics | ontology | codegen\n"
        "  targets: [jsonschema, xsd, postgres]\n"
        "  languages:\n"
        f"    identifiers: {langs[0]}\n"
        f"    documentation: [{', '.join(langs)}]\n"
        "  standards: []\n"
        "  sources: []\n\n"
        "enumerations: {}\n\ndatatypes: {}\n\nclasses: {}\n\nassociations: []\n\nconstraints: []\n"
    )
    for sub in ("releases", "exports"):
        (d / sub).mkdir(parents=True, exist_ok=True)
        (d / sub / ".gitkeep").touch()
    (d / "model.yaml").write_text(model, encoding="utf-8")
    created = ["model.yaml"]
    for fn, content in INIT_FILES.items():
        if not (d / fn).exists():
            (d / fn).write_text(content, encoding="utf-8")
            created.append(fn)
    print(f"initialised {d}: {', '.join(created)}, releases/, exports/")


def latest_release(d):
    rel = Path(d) / "releases"
    versions = [p.name for p in rel.iterdir() if p.is_dir() and semver(p.name) and (p / "model.yaml").exists()] \
        if rel.exists() else []
    return max(versions, key=semver) if versions else None


def set_header(text_, version, status):
    """Set model.version and model.status in the YAML text, keeping comments and layout."""
    lines = text_.splitlines(keepends=True)
    start = next((i for i, ln in enumerate(lines) if re.match(r"^model:\s*(#.*)?$", ln)), None)
    if start is None:
        raise SystemExit("model.yaml: no top-level 'model:' block found")
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^\S", lines[i]) and not lines[i].startswith("#")),
               len(lines))
    vi = si = None
    for i in range(start + 1, end):
        if re.match(r"^\s+version:", lines[i]) and vi is None:
            vi = i
        if re.match(r"^\s+status:", lines[i]) and si is None:
            si = i
    if vi is None:
        raise SystemExit("model.yaml: model.version not found")
    indent = re.match(r"^(\s+)", lines[vi]).group(1)
    nl = "\n" if lines[vi].endswith("\n") else ""
    lines[vi] = f"{indent}version: {version}{nl}"
    if si is not None:
        lines[si] = re.sub(r"(status:\s*)[^#\n]*", rf"\g<1>{status}  " if "#" in lines[si] else rf"\g<1>{status}", lines[si], count=1)
    else:
        lines.insert(vi + 1, f"{indent}status: {status}\n")
    return "".join(lines)


def changelog_entry(version, date, changes, first):
    if first:
        return f"## {version} — {date}\n\nFirst release.\n<!-- Sources: … -->\n"
    sections = {"Added": [], "Changed": [], "Deprecated": [], "Removed": []}
    for lvl, path, msg, tag in changes:
        if msg.startswith("hint:"):
            continue
        key = "Added" if " added" in msg.split(" —")[0] or msg.startswith("added") else \
            "Deprecated" if "deprecated" in msg.split(" —")[0] else \
            "Removed" if "removed" in msg.split(" —")[0] else "Changed"
        sections[key].append(f"- `{path}`: {msg}")
    out = [f"## {version} — {date}", "", "<!-- generated by dmtool release — review, add sources and decisions -->"]
    for k, items in sections.items():
        if items:
            out += ["", f"### {k}"] + items
    breaking = [c for c in changes if c[3] == "breaking"]
    consumer = [c for c in changes if c[3] == "consumer-breaking"]
    out += ["", "### Compatibility"]
    if not breaking and not consumer:
        out.append("- No breaking changes.")
    if breaking:
        out.append(f"- **Breaking for existing data/consumers** ({len(breaking)}): "
                   + ", ".join(f"`{c[1]}`" for c in breaking) + ". Migration notes: <!-- fill in -->")
    if consumer:
        out.append(f"- **Breaks consumers that validate strictly against the previous release** ({len(consumer)}): "
                   + ", ".join(f"`{c[1]}`" for c in consumer)
                   + ". Serve them a projection without the new elements, or agree on open content.")
    return "\n".join(out) + "\n"


def release(d, version=None, date=None, dry_run=False):
    d = Path(d)
    mp = d / "model.yaml"
    if not mp.exists():
        sys.exit(f"{mp} not found (run 'dmtool.py init {d}' first)")
    m = load(mp)
    errors, warnings, _ = validate(m, mp, as_released=True)
    if errors:
        print("Cannot release — validation errors:", *errors, sep="\n  ", file=sys.stderr)
        sys.exit(1)
    for w in warnings:
        print(f"WARNING {w}")
    cur = str(m["model"].get("version"))
    prev = latest_release(d)
    changes = []
    if prev:
        mo = load(d / "releases" / prev / "model.yaml")
        mode = consumer_mode(mo)
        changes = diff(mo, m)
        rec, _, level = recommend(prev, cur, changes)
        if level == -1:
            sys.exit(f"no changes since release {prev} — nothing to release")
        print_diff(changes, prev, cur, mode)
        target = version or (cur if semver(cur) > semver(prev) and semver(cur) >= semver(rec) else rec)
        if semver(target) < semver(rec):
            sys.exit(f"version {target} is too low: the changes since {prev} need at least {rec}")
    else:
        target = version or cur
    if not semver(target):
        sys.exit(f"'{target}' is not a semantic version")
    if (d / "releases" / target).exists():
        sys.exit(f"releases/{target} already exists — releases are never overwritten")
    date = date or datetime.date.today().isoformat()
    new_text = set_header(mp.read_text(encoding="utf-8"), target, "released")
    m2 = load_from(yaml.safe_load(new_text))
    targets = [t for t in (m2["model"].get("targets") or TARGETS) if t in EXPORTERS]
    entry = changelog_entry(target, date, changes, first=not prev)
    plan = [f"model.yaml: version {cur} → {target}, status released",
            f"releases/{target}/model.yaml",
            *[f"exports/{target}/{EXPORT_FILES[t]}" for t in targets],
            f"exports/{target}/diagram.mmd",
            "CHANGELOG.md: new entry"]
    print(("Would write:" if dry_run else "Release " + target + ":"), *plan, sep="\n  ")
    if dry_run:
        print("\n" + entry)
        return
    mp.write_text(new_text, encoding="utf-8")
    rd = d / "releases" / target
    rd.mkdir(parents=True)
    (rd / "model.yaml").write_text(new_text, encoding="utf-8")
    ed = d / "exports" / target
    ed.mkdir(parents=True, exist_ok=True)
    for t in targets:
        (ed / EXPORT_FILES[t]).write_text(EXPORTERS[t](m2), encoding="utf-8")
    (ed / "diagram.mmd").write_text(diagram(m2), encoding="utf-8")
    cl = d / "CHANGELOG.md"
    old = cl.read_text(encoding="utf-8") if cl.exists() else "# Changelog\n"
    head, sep, rest = old.partition("\n")
    if head.startswith("# "):
        cl.write_text(f"{head}\n\n{entry}\n{rest.lstrip(chr(10))}", encoding="utf-8")
    else:
        cl.write_text(f"# Changelog\n\n{entry}\n{old}", encoding="utf-8")
    print(f"\nReleased {target}. Review the CHANGELOG entry (sources, decisions, migration notes).")


# --------------------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init", help="create a model workspace")
    i.add_argument("dir", nargs="?", default="datamodel")
    i.add_argument("--name", default="DataModel")
    i.add_argument("--namespace")
    i.add_argument("--languages", default="en", help="documentation languages, default first (e.g. en,de)")
    v = sub.add_parser("validate"); v.add_argument("model")
    d = sub.add_parser("diagram"); d.add_argument("model"); d.add_argument("-o", "--output")
    e = sub.add_parser("export"); e.add_argument("model"); e.add_argument("-o", "--output")
    e.add_argument("--format", required=True, choices=[*TARGETS, "all"])
    e.add_argument("--lang", help="documentation language for descriptions and comments (default: first declared)")
    df = sub.add_parser("diff"); df.add_argument("old"); df.add_argument("new")
    df.add_argument("--consumers", choices=["strict", "tolerant"],
                    help="override how consumers validate (default: from the old model)")
    df.add_argument("--json", action="store_true")
    r = sub.add_parser("release", help="validate, snapshot, export and write a CHANGELOG entry")
    r.add_argument("dir", nargs="?", default="datamodel")
    r.add_argument("--version"); r.add_argument("--date"); r.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")

    if args.cmd == "init":
        init_workspace(args.dir, args.name, args.namespace, args.languages)
        return
    if args.cmd == "release":
        release(args.dir, args.version, args.date, args.dry_run)
        return
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
        if args.cmd == "export" and args.lang and args.lang not in doc_langs(m):
            sys.exit(f"--lang {args.lang} is not a declared documentation language {doc_langs(m)}")
        if args.cmd == "export" and args.format == "all":
            if not args.output:
                sys.exit("--format all needs -o <directory>")
            od = Path(args.output)
            od.mkdir(parents=True, exist_ok=True)
            for t in [t for t in (m["model"].get("targets") or TARGETS) if t in EXPORTERS]:
                (od / EXPORT_FILES[t]).write_text(EXPORTERS[t](m, args.lang), encoding="utf-8")
                print(f"wrote {od / EXPORT_FILES[t]}")
            (od / "diagram.mmd").write_text(diagram(m), encoding="utf-8")
            print(f"wrote {od / 'diagram.mmd'}")
            return
        out = diagram(m) if args.cmd == "diagram" else EXPORTERS[args.format](m, args.lang)
        if args.output:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(out, encoding="utf-8")
            print(f"wrote {args.output}")
        else:
            sys.stdout.write(out)
        return
    if args.cmd == "diff":
        mo, mn = load(args.old), load(args.new)
        mode = consumer_mode(mo, args.consumers)
        changes = diff(mo, mn, args.consumers)
        ov, nv = mo["model"].get("version"), mn["model"].get("version")
        rec, ok, level = recommend(ov, nv, changes)
        if args.json:
            print(json.dumps({"from": ov, "to": nv, "consumers": mode, "recommendedVersion": rec, "versionOk": ok,
                              "changes": [{"level": lv, "tag": t, "element": p, "change": c} for lv, p, c, t in changes]},
                             indent=2, ensure_ascii=False))
            return
        print_diff(changes, ov, nv, mode)
        if rec:
            print(f"Recommended version: {rec}" + ("" if ok is None else
                  ("  (new version OK)" if ok else f"  — model.version {nv} is too low")))
        if any(c[3] == "consumer-breaking" for c in changes):
            print("Some additions break consumers that validate strictly against the released schema. Options: "
                  "serve them a projection without the new elements, agree on open content, or release a major version.")
        if any(c[3] == "breaking" for c in changes):
            print("Breaking changes present: get an explicit decision, log it, and write migration notes.")


if __name__ == "__main__":
    main()
