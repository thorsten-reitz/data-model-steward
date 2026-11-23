"""Load the canonical model and offer small helpers shared by the generators."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
MODEL_PATH = ROOT / "model" / "airquality.model.yaml"


@dataclass
class Attr:
    key: str            # canonical / JSON name
    spec: dict

    @property
    def type(self) -> str:
        return self.spec["type"]

    @property
    def required(self) -> bool:
        return bool(self.spec.get("required", False))

    @property
    def multivalued(self) -> bool:
        return bool(self.spec.get("multivalued", False))

    @property
    def nullable(self) -> bool:
        return bool(self.spec.get("nullable", False))

    @property
    def xml(self) -> dict:
        return self.spec.get("xml", {}) or {}

    @property
    def xml_name(self) -> str:
        return self.xml.get("name", self.key)

    @property
    def is_xml_attribute(self) -> bool:
        return bool(self.xml.get("attribute", False))

    @property
    def description(self) -> str:
        return " ".join(str(self.spec.get("description", "")).split())


class Model:
    def __init__(self, path: Path = MODEL_PATH):
        self.raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        self.meta = self.raw["model"]
        self.root = self.raw["root"]
        self.types = self.raw["types"]
        self.enums = self.raw["enums"]
        self.classes = self.raw["classes"]

    def attrs(self, cls: str) -> list[Attr]:
        return [Attr(k, v) for k, v in self.classes[cls]["attributes"].items()]

    def kind(self, type_name: str) -> str:
        if type_name in self.types:
            return "scalar"
        if type_name in self.enums:
            return "enum"
        if type_name in self.classes:
            return "class"
        raise KeyError(f"Unknown type {type_name!r}")

    def scalar_base(self, attr: Attr) -> str:
        """Scalar type name used for value conversion (enums -> their base)."""
        if self.kind(attr.type) == "enum":
            return self.enums[attr.type].get("base", "string")
        return attr.type
