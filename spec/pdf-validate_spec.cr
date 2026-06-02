require "./spec_helper"

# Builds a PDF/A-2b-shaped document in memory (pdfaid + sRGB output
# intent, no encryption). Mirrors what the pdf-a shard configures,
# without depending on it.
private def pdfa_bytes : Bytes
  pdf = PDF::Document.new
  pdf.pdfa_part = 2
  pdf.pdfa_conformance = "B"
  pdf.output_intent = PDF::OutputIntent.srgb
  pdf.page { |_| }
  pdf.to_slice
end

# A plain (non-PDF/A) document.
private def plain_bytes : Bytes
  pdf = PDF::Document.new
  pdf.page { |_| }
  pdf.to_slice
end

describe PDF::Validate::RuleSet do
  it "knows the pdf-a-2b profile" do
    PDF::Validate::RuleSet.profiles.should contain("pdf-a-2b")
  end

  it "parses the embedded pdf-a-2b rule set" do
    rules = PDF::Validate::RuleSet.for("pdf-a-2b")
    rules.size.should be > 0
    rules.all? { |r| !r.clause.empty? }.should be_true
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
    failed_ids.should contain("pdfa2-6.7.11-pdfaid-part")
    failed_ids.should contain("pdfa2-6.2.2-output-intent")

    # Every failure carries its ISO clause.
    report.failures.all? { |r| r.rule.clause.starts_with?("ISO 19005") }.should be_true
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
