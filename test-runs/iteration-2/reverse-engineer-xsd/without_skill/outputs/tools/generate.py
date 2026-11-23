"""Generate the XSD (wire-compatible with partner 2.1) and the JSON Schema
from model/airquality.model.yaml.

    python tools/generate.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import ROOT, Attr, Model  # noqa: E402

OUT = ROOT / "generated"
HEADER = "Generated from model/airquality.model.yaml by tools/generate.py - do not edit."


def clean(text) -> str:
    return " ".join(str(text or "").split())


# --------------------------------------------------------------------------- XSD

def xsd(model: Model) -> str:
    m = model.meta
    pfx = m["xml"]["prefix"]
    lines: list[str] = []
    w = lines.append

    def doc(text: str, ind: str):
        if text:
            w(f'{ind}<xs:annotation><xs:documentation>{escape(clean(text))}</xs:documentation></xs:annotation>')

    def type_ref(a: Attr) -> str:
        if "type" in a.xml:
            return a.xml["type"]
        k = model.kind(a.type)
        if k == "scalar":
            return model.types[a.type]["xsd"]
        if k == "enum":
            e = model.enums[a.type]
            if e.get("xml", {}).get("emit", True) is False:
                raise ValueError(f"{a.key}: enum {a.type} not emitted to XSD, needs xml.type")
            return f'{pfx}:{e["xml"]["typeName"]}'
        return f'{pfx}:{model.classes[a.type]["xml"]["typeName"]}'

    def content(cls: str, ind: str):
        attrs = model.attrs(cls)
        elems = [a for a in attrs if not a.is_xml_attribute]
        xattrs = [a for a in attrs if a.is_xml_attribute]
        w(f"{ind}<xs:sequence>")
        for a in elems:
            occ = ""
            if not a.required:
                occ += ' minOccurs="0"'
            if a.multivalued:
                occ += ' maxOccurs="unbounded"'
            nil = ' nillable="true"' if a.nullable else ""
            head = f'{ind}  <xs:element name="{a.xml_name}" type="{type_ref(a)}"{occ}{nil}'
            if a.description:
                w(head + ">")
                doc(a.description, ind + "    ")
                w(f"{ind}  </xs:element>")
            else:
                w(head + "/>")
        w(f"{ind}</xs:sequence>")
        for a in xattrs:
            use = "required" if a.required else "optional"
            w(f'{ind}<xs:attribute name="{a.xml_name}" type="{type_ref(a)}" use="{use}">')
            doc(a.description, ind + "  ")
            w(f"{ind}</xs:attribute>")

    w('<?xml version="1.0" encoding="UTF-8"?>')
    w(f"<!-- {HEADER} -->")
    w(f'<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:{pfx}="{m["xml"]["namespace"]}"')
    w(f'           targetNamespace="{m["xml"]["namespace"]}" elementFormDefault="{m["xml"]["elementFormDefault"]}"'
      f' version="{m["xml"]["schemaVersion"]}">')
    doc(m.get("description"), "  ")

    root = model.classes[model.root]
    w(f'  <xs:element name="{root["xml"]["element"]}">')
    doc(root.get("description"), "    ")
    w("    <xs:complexType>")
    content(model.root, "      ")
    w("    </xs:complexType>")
    w("  </xs:element>")

    for name, cls in model.classes.items():
        if name == model.root:
            continue
        w(f'  <xs:complexType name="{cls["xml"]["typeName"]}">')
        doc(cls.get("description"), "    ")
        content(name, "    ")
        w("  </xs:complexType>")

    for name, e in model.enums.items():
        if e.get("xml", {}).get("emit", True) is False:
            continue
        base = model.types[e.get("base", "string")]["xsd"]
        w(f'  <xs:simpleType name="{e["xml"]["typeName"]}">')
        doc(e.get("description"), "    ")
        w(f'    <xs:restriction base="{base}">')
        for v, d in e["values"].items():
            w(f'      <xs:enumeration value="{v}">')
            doc(d, "        ")
            w("      </xs:enumeration>")
        w("    </xs:restriction>")
        w("  </xs:simpleType>")
    w("</xs:schema>")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- JSON Schema

def json_schema(model: Model) -> dict:
    m = model.meta
    defs: dict = {}

    def scalar_schema(type_name: str) -> dict:
        return dict(model.types[type_name]["json"])

    def attr_schema(a: Attr) -> dict:
        k = model.kind(a.type)
        if k == "class":
            item = {"$ref": f"#/$defs/{a.type}"}
        elif k == "enum":
            item = {"$ref": f"#/$defs/{a.type}"}
        else:
            item = scalar_schema(a.type)
            item.update(a.spec.get("json", {}))
        if a.nullable:
            if "$ref" in item:
                item = {"anyOf": [item, {"type": "null"}]}
            else:
                item["type"] = [item["type"], "null"]
        if a.multivalued:
            item = {"type": "array", "items": item}
            if a.required:
                item["minItems"] = 1
        if a.description:
            item = {"description": a.description, **item}
        return item

    for name, e in model.enums.items():
        base = e.get("base", "string")
        if base == "string":
            schema = {"type": "string", "enum": list(e["values"].keys())}
        else:
            schema = {
                "type": "integer",
                "oneOf": [{"const": v, "description": clean(d)} for v, d in e["values"].items()],
            }
        defs[name] = {"title": name, "description": clean(e.get("description")), **schema}
        if base == "string":
            defs[name]["x-enumDescriptions"] = {v: clean(d) for v, d in e["values"].items()}

    for name, cls in model.classes.items():
        props = {a.key: attr_schema(a) for a in model.attrs(name)}
        required = [a.key for a in model.attrs(name) if a.required]
        defs[name] = {
            "title": name,
            "description": clean(cls.get("description")),
            "type": "object",
            "properties": props,
            "required": required,
            "additionalProperties": False,
            "x-xml": {k: v for k, v in cls["xml"].items()},
        }

    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": m["json"]["id"],
        "title": m["json"]["title"],
        "description": clean(m.get("description")) + " " + HEADER,
        "x-model-version": m["version"],
        "x-xml-namespace": m["xml"]["namespace"],
        "$ref": f"#/$defs/{model.root}",
        "$defs": defs,
    }


def main():
    model = Model()
    OUT.mkdir(exist_ok=True)
    (OUT / "observations.xsd").write_text(xsd(model), encoding="utf-8")
    (OUT / "airquality.schema.json").write_text(
        json.dumps(json_schema(model), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("wrote", OUT / "observations.xsd")
    print("wrote", OUT / "airquality.schema.json")


if __name__ == "__main__":
    main()
