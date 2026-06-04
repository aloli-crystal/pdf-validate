require "pdf"

# Declarative PDF conformance validator (ALOLI ISO PDF suite, J5).
#
# A generic engine loads rule sets — YAML, one per profile — and
# evaluates each rule against a parsed PDF. Every rule traces to its
# ISO clause, so a validation report doubles as an audit trail.
#
# This is the focused, veraPDF-style validator the RATIONALE calls
# for : not a general-purpose PDF analyser, but a checker restricted
# to the profiles ALOLI targets (PDF/A-2b first).
#
# ## Usage
#
# ```
# require "pdf-validate"
#
# report = PDF::Validate.file("doc.pdf", profile: "pdf-a-2b")
# report.conformant? # => true / false
# report.failures    # => Array(Result) of failed rules
# puts report.to_s   # human-readable report
# ```
#
# ## Scope of this first palier (0.1.0)
#
# The engine is real : it parses the PDF via `PDF::Reader` and
# evaluates a vocabulary of checks against the actual catalog,
# trailer and XMP metadata. The shipped `pdf-a-2b` rule set covers
# the document-level requirements that can be checked from those
# structures (PDF/A identification, output intent, no encryption).
#
# It is NOT yet the full veraPDF-parity validator : per-resource
# rules (font embedding/subsetting, calibrated colour spaces,
# transparency groups, glyph-level checks) and the 95 %-agreement
# corpus criterion come in later paliers. The report says so.

require "./pdf-validate/version"
require "./pdf-validate/rule"
require "./pdf-validate/byte_scanner"
require "./pdf-validate/content_stream_scanner"
require "./pdf-validate/xmp_extension_schema"
require "./pdf-validate/jpeg2000"
require "./pdf-validate/context"
require "./pdf-validate/checks"
require "./pdf-validate/result"
require "./pdf-validate/rule_set"
require "./pdf-validate/engine"
require "./pdf-validate/report"
