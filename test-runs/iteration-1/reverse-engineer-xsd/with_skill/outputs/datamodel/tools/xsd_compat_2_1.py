"""Derive the partner-compatible XSD (wire format 2.1) from the generated XSD.

Decision D-005. The canonical model keeps identifiers as ordinary attributes; XSD 2.1
carries them as XML attributes `id` of type xs:ID, and types validity/verification as
xs:int. dmtool's XSD exporter cannot express either, so this script applies exactly
these deterministic adjustments to the generated file — nothing else:

  1. StationType       : add  <xs:attribute name="id" type="xs:ID" use="required"/>
                         (document-local; producer derives it from stationCode, consumer ignores it)
  2. SamplingPointType : drop element samplingPointId, add the same @id attribute
                         (canonical samplingPointId <-> XML @id)
  3. ObservationValidityType / VerificationStatusType : restriction base xs:string -> xs:int
  4. schema/@version   : "2.1" (wire-format version, not the model version)

Usage: python xsd_compat_2_1.py <generated.xsd> <out.xsd>
"""
import sys

from lxml import etree

XS = "http://www.w3.org/2001/XMLSchema"
Q = lambda t: f"{{{XS}}}{t}"  # noqa: E731


def complex_type(root, name):
    return root.find(f"{Q('complexType')}[@name='{name}']")


def add_id_attribute(ct):
    attr = etree.SubElement(ct, Q("attribute"), name="id", type="xs:ID", use="required")
    attr.tail = "\n  "
    ct[-2].tail = "\n    "


def main(src, dst):
    tree = etree.parse(src)
    root = tree.getroot()

    add_id_attribute(complex_type(root, "StationType"))

    sp = complex_type(root, "SamplingPointType")
    seq = sp.find(Q("sequence"))
    spid = seq.find(f"{Q('element')}[@name='samplingPointId']")
    seq.remove(spid)
    add_id_attribute(sp)

    for name in ("ObservationValidityType", "VerificationStatusType"):
        st = root.find(f"{Q('simpleType')}[@name='{name}']")
        st.find(Q("restriction")).set("base", "xs:int")

    root.set("version", "2.1")
    comment = etree.Comment(
        " GENERATED from datamodel/model.yaml by dmtool export + tools/xsd_compat_2_1.py (D-005). Do not edit. ")
    comment.tail = "\n  "
    root.insert(0, comment)
    tree.write(dst, xml_declaration=True, encoding="UTF-8")
    print(f"wrote {dst}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
