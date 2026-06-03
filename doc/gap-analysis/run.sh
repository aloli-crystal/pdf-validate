#!/usr/bin/env bash
# Regenerates the ISO 19005-2 gap-analysis coverage table by
# enumerating veraPDF's PDF/A-2b rule set and mapping it to the
# clauses pdf-validate's pdf-a-2b rule set addresses.
#
# Usage: doc/gap-analysis/run.sh <conformant-pdfa2b.pdf>
# Requires: veraPDF 1.30.1 on PATH, python3.
set -euo pipefail

PDF="${1:?usage: run.sh <conformant-pdfa2b.pdf>}"
RULES="$(cd "$(dirname "$0")/../.." && pwd)/rules/pdf-a-2b.yml"
TMP="$(mktemp).xml"

verapdf -f 2b --passed --format xml "$PDF" > "$TMP"

python3 - "$TMP" "$RULES" <<'PY'
import sys, re, collections, xml.etree.ElementTree as ET
vera, rules_yml = sys.argv[1], sys.argv[2]

# 1. veraPDF rule set (clause, testNumber)
uniq = {}
for r in ET.parse(vera).iter():
    if r.tag.endswith("rule") and r.get("clause"):
        uniq[(r.get("clause"), r.get("testNumber"))] = True

# 2. clauses our rule set addresses (parse the YAML clause: lines)
ours = set()
for line in open(rules_yml):
    m = re.search(r'clause:\s*"ISO 19005-2 § ([\d.]+)"', line)
    if m:
        ours.add(m.group(1))

# Distinct sub-clauses that prefix-match an ancestor we DO list, but
# that cover a separate sub-topic we have NOT implemented. Kept
# explicit so the coverage figure is not silently inflated.
#   6.2.8.3 — JPEG2000 codestream conformance (a descendant of 6.2.8,
#             whose t1-t5 image-dictionary keys we check, but the
#             JPEG2000 codestream parsing we do not).
not_covered = {"6.2.8.3"}

# Individual tests we do NOT implement, counted at test granularity so
# a heterogeneous clause is not over-claimed :
#   6.1.13 t10 — maximum CID value (needs a CMap interpreter)
#   6.2.2  t2  — content stream references all objects needed to render
#                (resource-completeness, not operator validity)
#   6.8    t5  — the embedded file must itself be PDF/A-1/2 (recursive
#                validation)
#   6.2.4.2 t2 — overprint mode for ICCBased CMYK (graphics state)
#   6.4.3  t2-t3 — PKCS#7 signing certificate / SignerInfo count
#                  (ASN.1/DER parsing — belongs in pdf-signature)
#   6.6.2.3.1 t1-t2 — every XMP property must belong to a predefined or
#                     defined schema (needs the full XMP-2005 schema set)
not_covered_tests = {
    ("6.1.13", "10"), ("6.2.2", "2"), ("6.8", "5"),
    ("6.2.4.2", "2"),
    ("6.4.3", "2"), ("6.4.3", "3"),
    ("6.6.2.3.1", "1"), ("6.6.2.3.1", "2"),
}

def covered(cl, tn):
    if cl in not_covered:
        return False
    if (cl, tn) in not_covered_tests:
        return False
    return any(cl == o or cl.startswith(o + ".") for o in ours)

labels = {
    "6.1": "File structure", "6.2": "Graphics (colour, fonts, transparency)",
    "6.3": "Annotations", "6.4": "Digital signatures", "6.5": "Actions",
    "6.6": "Metadata (XMP, pdfaid)", "6.8": "Embedded files",
    "6.9": "Optional content", "6.10": "Alternate presentations",
    "6.11": "Requirements key",
}
sec = collections.defaultdict(lambda: [0, 0])
for (cl, tn) in uniq:
    s = re.match(r"(\d+\.\d+)", cl).group(1)
    sec[s][0] += 1
    if covered(cl, tn):
        sec[s][1] += 1

tot = cov = 0
print(f"{'Section':<8}{'Theme':<46}{'veraPDF':>8}{'covered':>9}")
for s in sorted(sec, key=lambda x: [int(n) for n in x.split('.')]):
    n, c = sec[s]; tot += n; cov += c
    print(f"§{s:<7}{labels.get(s,'?'):<46}{n:>8}{c:>9}")
print(f"{'TOTAL':<54}{tot:>8}{cov:>9}")
print(f"\nClause-level coverage: {cov}/{tot} = {100*cov//tot}%")
PY

rm -f "$TMP"
