"""Model-driven conversion between the XML (2.1) and JSON representations.

    python tools/convert.py xml2json in.xml  > out.json
    python tools/convert.py json2xml in.json > out.xml

Both directions are driven by model/airquality.model.yaml, so field renames
(e.g. sampling -> samplingPoints) live in exactly one place.
"""
from __future__ import annotations

import json
import math
import sys
from decimal import Decimal
from pathlib import Path

from lxml import etree

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import Model  # noqa: E402

XSI_NIL = "{http://www.w3.org/2001/XMLSchema-instance}nil"


def _parse_scalar(base: str, text: str):
    text = text.strip()
    if base == "integer":
        return int(text)
    if base == "decimal":
        d = Decimal(text)
        return int(d) if d == d.to_integral_value() and "." not in text else float(d)
    if base == "double":
        v = float(text.replace("INF", "inf"))
        if math.isnan(v) or math.isinf(v):
            raise ValueError(f"NaN/INF not representable in JSON / canonical model: {text!r}")
        return v
    return text  # string, dateTime, documentId


def _format_scalar(base: str, value) -> str:
    if base in ("decimal", "double") and isinstance(value, float):
        return repr(value)
    return str(value)


def xml_to_obj(model: Model, elem, cls: str) -> dict:
    ns = model.meta["xml"]["namespace"]
    out: dict = {}
    for a in model.attrs(cls):
        if a.is_xml_attribute:
            if elem.get(a.xml_name) is not None:
                out[a.key] = _parse_scalar(model.scalar_base(a), elem.get(a.xml_name))
            continue
        children = elem.findall(f"{{{ns}}}{a.xml_name}")
        vals = []
        for c in children:
            if c.get(XSI_NIL) in ("true", "1"):
                vals.append(None)
            elif model.kind(a.type) == "class":
                vals.append(xml_to_obj(model, c, a.type))
            else:
                vals.append(_parse_scalar(model.scalar_base(a), c.text or ""))
        if a.multivalued:
            if vals or a.required:
                out[a.key] = vals
        elif vals:
            out[a.key] = vals[0]
    return out


def obj_to_xml(model: Model, obj: dict, cls: str, tag: str):
    ns = model.meta["xml"]["namespace"]
    pfx = model.meta["xml"]["prefix"]
    elem = etree.Element(f"{{{ns}}}{tag}", nsmap={pfx: ns} if cls == model.root else None)
    for a in model.attrs(cls):
        if a.key not in obj:
            continue
        if a.is_xml_attribute:
            elem.set(a.xml_name, _format_scalar(model.scalar_base(a), obj[a.key]))
            continue
        values = obj[a.key] if a.multivalued else [obj[a.key]]
        for v in values:
            if model.kind(a.type) == "class" and v is not None:
                elem.append(obj_to_xml(model, v, a.type, a.xml_name))
                continue
            child = etree.SubElement(elem, f"{{{ns}}}{a.xml_name}")
            if v is None:
                child.set(XSI_NIL, "true")
            else:
                child.text = _format_scalar(model.scalar_base(a), v)
    return elem


def xml2json(model: Model, xml_bytes: bytes) -> dict:
    root = etree.fromstring(xml_bytes)
    return xml_to_obj(model, root, model.root)


def json2xml(model: Model, obj: dict) -> bytes:
    tag = model.classes[model.root]["xml"]["element"]
    return etree.tostring(obj_to_xml(model, obj, model.root, tag),
                          xml_declaration=True, encoding="UTF-8", pretty_print=True)


def main():
    direction, path = sys.argv[1], Path(sys.argv[2])
    model = Model()
    if direction == "xml2json":
        print(json.dumps(xml2json(model, path.read_bytes()), indent=2, ensure_ascii=False))
    elif direction == "json2xml":
        sys.stdout.write(json2xml(model, json.loads(path.read_text(encoding="utf-8"))).decode("utf-8"))
    else:
        sys.exit("usage: convert.py xml2json|json2xml FILE")


if __name__ == "__main__":
    main()
