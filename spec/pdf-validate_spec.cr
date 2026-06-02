require "./spec_helper"

# Builds a PDF/A-2b-shaped document in memory (pdfaid + sRGB output
# intent, no encryption). Mirrors what the pdf-a shard configures,
# without depending on it.
private def pdfa_bytes : Bytes
  pdf = PDF::Document.new
  pdf.pdfa_part = 2
  pdf.pdfa_conformance = "B"
  pdf.output_intent = PDF::OutputIntent.srgb
  pdf.file_id # /ID required by PDF/A (ISO 19005-2 § 6.1.3)
  pdf.page { |_| }
  pdf.to_slice
end

# A plain (non-PDF/A) document.
private def plain_bytes : Bytes
  pdf = PDF::Document.new
  pdf.page { |_| }
  pdf.to_slice
end

# Hand-authors a minimal but well-formed PDF (classic xref table with
# computed byte offsets) whose page resources deliberately violate the
# § 6.2 graphics rules : an ExtGState carrying /TR + /TR2 (non-Default)
# + a non-standard /BM, and a form XObject with /Subtype2 /PS, /OPI and
# /Ref. Used to prove the new rules actually fire — the generated
# corpus is clean and cannot exercise the failure path.
private def pdf_with_graphics_violations : Bytes
  bodies = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /ExtGState << /GS0 4 0 R >> /XObject << /Fm0 5 0 R >> >> >>",
    "<< /Type /ExtGState /TR /Identity /TR2 /Foo /BM /Fancy >>",
    "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] " \
    "/Subtype2 /PS /OPI << >> /Ref << >> >>",
  ]
  io = IO::Memory.new
  io << "%PDF-1.7\n"
  offsets = [] of Int32
  bodies.each_with_index do |body, i|
    offsets << io.pos
    io << (i + 1) << " 0 obj\n" << body << "\nendobj\n"
  end
  xref_offset = io.pos
  count = bodies.size + 1
  io << "xref\n0 " << count << "\n"
  io << "0000000000 65535 f \n"
  offsets.each { |off| io << off.to_s.rjust(10, '0') << " 00000 n \n" }
  io << "trailer\n<< /Size " << count << " /Root 1 0 R >>\n"
  io << "startxref\n" << xref_offset << "\n%%EOF\n"
  io.to_slice
end

describe PDF::Validate::RuleSet do
  it "knows the pdf-a-2b profile" do
    PDF::Validate::RuleSet.profiles.should contain("pdf-a-2b")
  end

  it "parses the embedded pdf-a-2b rule set" do
    rules = PDF::Validate::RuleSet.for("pdf-a-2b")
    rules.size.should be > 0
    rules.all? { |rule| !rule.clause.empty? }.should be_true
  end

  it "raises for an unknown profile" do
    expect_raises(ArgumentError, /Unknown profile/) do
      PDF::Validate::RuleSet.for("pdf-x")
    end
  end
end

describe PDF::Validate do
  it "reports a PDF/A-shaped document as conformant (document-level)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.conformant?.should be_true
    report.failures.should be_empty
  end

  it "reports a plain document as non-conformant with traceable failures" do
    report = PDF::Validate.bytes(plain_bytes, "pdf-a-2b")
    report.conformant?.should be_false

    failed_ids = report.failures.map(&.rule.id)
    failed_ids.should contain("pdfa2-6.6.4-pdfaid-part")
    failed_ids.should contain("pdfa2-6.2.10-output-intent")

    # Every failure carries its ISO clause.
    report.failures.all?(&.rule.clause.starts_with?("ISO 19005")).should be_true
  end

  it "detects a non-embedded standard-14 font as a violation" do
    pdf = PDF::Document.new
    pdf.pdfa_part = 2
    pdf.pdfa_conformance = "B"
    pdf.output_intent = PDF::OutputIntent.srgb
    pdf.file_id
    pdf.page { |page| page.font "Helvetica", size: 12; page.text "x", at: {72, 700} }
    report = PDF::Validate.bytes(pdf.to_slice, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.4.1-fonts-embedded")
  end

  it "detects a missing /ID in the trailer as a violation" do
    pdf = PDF::Document.new
    pdf.pdfa_part = 2
    pdf.pdfa_conformance = "B"
    pdf.output_intent = PDF::OutputIntent.srgb
    # deliberately NOT calling file_id → no /ID
    pdf.page { |_| }
    report = PDF::Validate.bytes(pdf.to_slice, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.3-file-id")
  end

  it "detects encryption as a violation" do
    pdf = PDF::Document.new
    pdf.pdfa_part = 2
    pdf.pdfa_conformance = "B"
    pdf.output_intent = PDF::OutputIntent.srgb
    pdf.page { |_| }
    pdf.encrypt(owner_password: "x", level: :aes_256)
    report = PDF::Validate.bytes(pdf.to_slice, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.3-no-encryption")
  end

  it "detects § 6.2 graphics violations (ExtGState, blend modes, XObjects)" do
    report = PDF::Validate.bytes(pdf_with_graphics_violations, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should contain("pdfa2-6.2.5-extgstate-no-transfer")
    failed.should contain("pdfa2-6.2.10-standard-blend-modes")
    failed.should contain("pdfa2-6.2.9-no-forbidden-xobjects")
  end

  it "does not flag a clean document under the § 6.2 graphics rules" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.2.5-extgstate-no-transfer")
    failed.should_not contain("pdfa2-6.2.10-standard-blend-modes")
    failed.should_not contain("pdfa2-6.2.9-no-forbidden-xobjects")
  end

  it "produces JSON with the expected shape" do
    json = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b").to_json
    parsed = JSON.parse(json)
    parsed["profile"].as_s.should eq("pdf-a-2b")
    parsed["conformant"].as_bool.should be_true
    parsed["results"].as_a.size.should be > 0
  end

  it "renders a human-readable report" do
    text = PDF::Validate.bytes(plain_bytes, "pdf-a-2b").to_s
    text.should contain("PDF/Validate report")
    text.should contain("FAIL")
    text.should contain("ISO 19005")
  end
end

describe "pdf-ua-1 profile" do
  it "knows the pdf-ua-1 profile" do
    PDF::Validate::RuleSet.profiles.should contain("pdf-ua-1")
  end

  it "reports a tagged + lang + viewer-prefs + pdfuaid doc as conformant" do
    pdf = PDF::Document.new
    pdf.title = "Accessible"
    pdf.lang = "fr"
    pdf.pdfua_part = 1
    pdf.display_doc_title = true
    page = pdf.page { |_| }
    pdf.struct_tree do |tree|
      d = tree.add(PDF::Structure::Tag::DOCUMENT)
      p = d.add(PDF::Structure::Tag::P)
      page.tag(p) { page.font "Helvetica", size: 12; page.text "ok", at: {72, 700} }
    end

    report = PDF::Validate.bytes(pdf.to_slice, "pdf-ua-1")
    report.conformant?.should be_true
  end

  it "flags an untagged document as non-conformant for pdf-ua-1" do
    pdf = PDF::Document.new
    pdf.page { |_| }
    report = PDF::Validate.bytes(pdf.to_slice, "pdf-ua-1")
    report.conformant?.should be_false
    ids = report.failures.map(&.rule.id)
    ids.should contain("pdfua1-7.1-struct-tree-root")
    ids.should contain("pdfua1-5-pdfuaid-part")
  end
end

describe "third-party PDF/A (serialization robustness)" do
  # A PDF/A-2b produced by Ghostscript/ocrmypdf — a completely
  # different writer than the ALOLI shards. Its XMP serialises
  # pdfaid in *attribute* form (pdfaid:part="2") rather than element
  # form. veraPDF reports it conformant ; pdf-validate must agree
  # (regression guard for the false-positive bug fixed in 0.4.0).
  it "accepts attribute-form pdfaid (Ghostscript output)" do
    path = "#{__DIR__}/fixtures/ghostscript_pdfa2b.pdf"
    pending! "fixture missing" unless File.exists?(path)
    report = PDF::Validate.file(path, "pdf-a-2b")
    report.conformant?.should be_true
  end
end

describe PDF::Validate::Checks do
  it "raises on an unknown check primitive" do
    pdf = PDF::Document.new
    pdf.page { |_| }
    ctx = PDF::Validate::Context.new(PDF::Reader.open(IO::Memory.new(pdf.to_slice)))
    expect_raises(Exception, /Unknown check/) do
      PDF::Validate::Checks.evaluate("does_not_exist", [] of String, ctx)
    end
  end
end
