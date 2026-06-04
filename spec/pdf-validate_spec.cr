require "./spec_helper"

# A well-formed PDF/A extension schema (validated against veraPDF :
# all § 6.6.2.3 rules pass). Mutated in specs to forge violations.
VALID_EXTENSION_XMP = <<-XMP
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
   <pdfaExtension:schemas>
    <rdf:Bag>
     <rdf:li rdf:parseType="Resource">
      <pdfaSchema:schema>Custom Schema</pdfaSchema:schema>
      <pdfaSchema:namespaceURI>http://ns.example.com/custom/1.0/</pdfaSchema:namespaceURI>
      <pdfaSchema:prefix>custom</pdfaSchema:prefix>
      <pdfaSchema:property>
       <rdf:Seq>
        <rdf:li rdf:parseType="Resource">
         <pdfaProperty:name>myProp</pdfaProperty:name>
         <pdfaProperty:valueType>Text</pdfaProperty:valueType>
         <pdfaProperty:category>internal</pdfaProperty:category>
         <pdfaProperty:description>A custom property</pdfaProperty:description>
        </rdf:li>
       </rdf:Seq>
      </pdfaSchema:property>
     </rdf:li>
    </rdf:Bag>
   </pdfaExtension:schemas>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
XMP

# XMP using a property in a custom namespace that is neither predefined
# nor declared by an extension schema — violating § 6.6.2.3.1.
UNDECLARED_PROPERTY_XMP = <<-XMP
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:custom="http://ns.example.com/custom/1.0/">
   <custom:myProp>value</custom:myProp>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
XMP

# XMP that both declares the custom namespace via a PDF/A extension
# schema and uses a property in it — conformant under § 6.6.2.3.1.
DECLARED_PROPERTY_XMP = <<-XMP
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
   <pdfaExtension:schemas>
    <rdf:Bag>
     <rdf:li rdf:parseType="Resource">
      <pdfaSchema:schema>Custom Schema</pdfaSchema:schema>
      <pdfaSchema:namespaceURI>http://ns.example.com/custom/1.0/</pdfaSchema:namespaceURI>
      <pdfaSchema:prefix>custom</pdfaSchema:prefix>
      <pdfaSchema:property>
       <rdf:Seq>
        <rdf:li rdf:parseType="Resource">
         <pdfaProperty:name>myProp</pdfaProperty:name>
         <pdfaProperty:valueType>Text</pdfaProperty:valueType>
         <pdfaProperty:category>internal</pdfaProperty:category>
         <pdfaProperty:description>A custom property</pdfaProperty:description>
        </rdf:li>
       </rdf:Seq>
      </pdfaSchema:property>
     </rdf:li>
    </rdf:Bag>
   </pdfaExtension:schemas>
  </rdf:Description>
  <rdf:Description rdf:about="" xmlns:custom="http://ns.example.com/custom/1.0/">
   <custom:myProp>value</custom:myProp>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
XMP

private def pdf_with_undeclared_xmp_property : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    {"<< /Type /Metadata /Subtype /XML >>", UNDECLARED_PROPERTY_XMP.to_slice},
  ] of ObjBody)
end

private def pdf_with_declared_xmp_property : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    {"<< /Type /Metadata /Subtype /XML >>", DECLARED_PROPERTY_XMP.to_slice},
  ] of ObjBody)
end

# A PDF whose /Metadata carries an extension schema with an invalid
# property category, violating § 6.6.2.3.
private def pdf_with_invalid_extension_schema : Bytes
  xmp = VALID_EXTENSION_XMP.gsub("internal", "bogus")
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    {"<< /Type /Metadata /Subtype /XML >>", xmp.to_slice},
  ] of ObjBody)
end

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
# computed byte offsets) from a list of object bodies. A body is either
# a String (a dictionary/value object) or a {dict, bytes} tuple (a
# stream object — the writer-matching `dict\nstream\n…\nendstream`
# layout, with /Length injected). Used to prove the validator rules
# fire : the generated corpus is clean and cannot exercise the failure
# path.
private alias ObjBody = String | Tuple(String, Bytes)

private def build_pdf(objects : ::Array(ObjBody), binary_comment : Bool = true) : Bytes
  io = IO::Memory.new
  io << "%PDF-1.7\n"
  # Binary-marker comment (§ 6.1.2 t2) : % + four bytes > 127.
  io.write(Bytes[0x25_u8, 0xE2_u8, 0xE3_u8, 0xCF_u8, 0xD3_u8, 0x0A_u8]) if binary_comment
  offsets = [] of Int32
  objects.each_with_index do |obj, i|
    offsets << io.pos
    io << (i + 1) << " 0 obj\n"
    case obj
    in String
      io << obj
    in Tuple(String, Bytes)
      dict, bytes = obj
      io << dict.rchop(">>").rstrip << " /Length " << bytes.size << " >>"
      io << "\nstream\n"
      io.write(bytes)
      io << "\nendstream"
    end
    io << "\nendobj\n"
  end
  xref_offset = io.pos
  count = objects.size + 1
  io << "xref\n0 " << count << "\n"
  io << "0000000000 65535 f \n"
  offsets.each { |off| io << off.to_s.rjust(10, '0') << " 00000 n \n" }
  io << "trailer\n<< /Size " << count << " /Root 1 0 R >>\n"
  io << "startxref\n" << xref_offset << "\n%%EOF\n"
  io.to_slice
end

# Violates the § 6.2 graphics rules : an ExtGState carrying /TR + /TR2
# (non-Default) + a non-standard /BM, and a form XObject with
# /Subtype2 /PS, /OPI and /Ref.
private def pdf_with_graphics_violations : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /ExtGState << /GS0 4 0 R >> /XObject << /Fm0 5 0 R >> >> >>",
    "<< /Type /ExtGState /TR /Identity /TR2 /Foo /BM /Fancy >>",
    "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] " \
    "/Subtype2 /PS /OPI << >> /Ref << >> >>",
  ] of ObjBody)
end

# Violates § 6.2.8 (image dictionary keys : /Alternates, /OPI,
# /Interpolate true, invalid /BitsPerComponent) and § 6.2.6 (a
# non-standard rendering /Intent), both on one image XObject.
private def pdf_with_image_violations : Bytes
  image = {
    "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 " \
    "/BitsPerComponent 3 /ColorSpace /DeviceGray /Interpolate true " \
    "/Intent /Foo /Alternates [] /OPI << >> >>",
    Bytes[0_u8],
  }
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /XObject << /Im0 4 0 R >> >> >>",
    image,
  ] of ObjBody)
end

# Violates § 6.2.3 : the DestOutputProfile is an ICC stream whose
# header declares the "spac" (colour-space-conversion) device class,
# which PDF/A forbids for an output intent (only "prtr"/"mntr").
private def pdf_with_bad_output_intent : Bytes
  icc = Bytes.new(132, 0_u8)
  icc[8] = 2_u8 # ICC major version 2
  "spac".to_slice.each_with_index { |byte, i| icc[12 + i] = byte }
  "RGB ".to_slice.each_with_index { |byte, i| icc[16 + i] = byte }
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /OutputIntents [4 0 R] >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /OutputIntent /S /GTS_PDFA1 " \
    "/OutputConditionIdentifier (sRGB) /DestOutputProfile 5 0 R >>",
    {"<< /N 3 >>", icc},
  ] of ObjBody)
end

# A single Movie annotation, with no /F and no /AP and a non-degenerate
# /Rect, violates all three § 6.3 rules at once : forbidden subtype
# (§ 6.3.1), missing flags (§ 6.3.2), missing appearance (§ 6.3.3).
private def pdf_with_annotation_violations : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
    "<< /Type /Annot /Subtype /Movie /Rect [0 0 100 100] >>",
  ] of ObjBody)
end

# Structural violations in one document : a content stream with a
# forbidden LZWDecode filter (§ 6.1.7.2) and an external-file /F key
# (§ 6.1.7.1), plus a catalog carrying /Requirements (§ 6.11),
# /Names /AlternatePresentations and a page /PresSteps (§ 6.10).
private def pdf_with_structure_violations : Bytes
  lzw_stream = {"<< /Filter /LZWDecode /F (external.dat) >>", Bytes[0_u8]}
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Requirements [] " \
    "/Names << /AlternatePresentations << >> >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/PresSteps << >> /Contents 4 0 R >>",
    lzw_stream,
  ] of ObjBody)
end

# A file violating § 6.4 : catalog /NeedsRendering, AcroForm with
# /NeedAppearances true and /XFA, and a Widget field carrying /A and
# /AA.
private def pdf_with_form_violations : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /NeedsRendering true " \
    "/AcroForm << /Fields [4 0 R] /NeedAppearances true /XFA 5 0 R >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
    "<< /Type /Annot /Subtype /Widget /FT /Btn /Rect [0 0 10 10] " \
    "/A << /S /URI >> /AA << >> >>",
    {"<< >>", "xfa".to_slice},
  ] of ObjBody)
end

# A page referencing a Type1 font dictionary with no /BaseFont,
# violating § 6.2.11.2 (t3).
private def pdf_with_bad_font : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type1 >>",
  ] of ObjBody)
end

# A Type0 font whose CMap-stream /CIDSystemInfo (Adobe-GB1) does not
# match the descendant CIDFont (Adobe-Japan1), violating § 6.2.11.3.1.
private def pdf_with_mismatched_cidsysteminfo : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding 7 0 R /DescendantFonts [5 0 R] >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo " \
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 0 >> " \
    "/FontDescriptor 6 0 R /CIDToGIDMap /Identity >>",
    "<< /Type /FontDescriptor /FontName /Foo >>",
    {"<< /Type /CMap /CMapName /Custom /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 0 >> /WMode 0 >>", "begincmap".to_slice},
  ] of ObjBody)
end

# A Type0 font with the Identity-H encoding (the common case), which
# must NOT trip § 6.2.11.3.1.
private def pdf_with_identity_type0 : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo " \
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /CIDToGIDMap /Identity >>",
  ] of ObjBody)
end

# A non-symbolic simple TrueType font (Flags 32) whose /Encoding is
# StandardEncoding — violating § 6.2.11.6 t2 (must be MacRoman/WinAnsi).
private def pdf_with_bad_truetype_encoding : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /TrueType /BaseFont /Arial /Encoding /StandardEncoding /FontDescriptor 5 0 R >>",
    "<< /Type /FontDescriptor /FontName /Arial /Flags 32 >>",
  ] of ObjBody)
end

# A symbolic simple TrueType font (Flags 4) carrying an /Encoding entry
# — violating § 6.2.11.6 t3 (symbolic fonts must have no Encoding).
private def pdf_with_symbolic_truetype_encoding : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /TrueType /BaseFont /Sym /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>",
    "<< /Type /FontDescriptor /FontName /Sym /Flags 4 >>",
  ] of ObjBody)
end

# A conformant non-symbolic TrueType font : WinAnsiEncoding, Flags 32.
private def pdf_with_good_truetype_encoding : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /TrueType /BaseFont /Arial /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>",
    "<< /Type /FontDescriptor /FontName /Arial /Flags 32 >>",
  ] of ObjBody)
end

# Builds a minimal sfnt TrueType program with a single `cmap` table
# whose encoding records are the given (platform_id, encoding_id) pairs,
# all pointing at one shared format-0 subtable. Enough for the
# § 6.2.11.6 t1/t4 cmap-subtable checks (no glyf/head/maxp needed).
private def truetype_program_with_cmap(records : Array(Tuple(Int32, Int32))) : Bytes
  be = IO::ByteFormat::BigEndian
  cmap = IO::Memory.new
  cmap.write_bytes(0_u16, be)                # version
  cmap.write_bytes(records.size.to_u16, be)  # numTables
  sub_offset = (4 + 8 * records.size).to_u32 # header + records
  records.each do |platform, encoding|
    cmap.write_bytes(platform.to_u16, be)
    cmap.write_bytes(encoding.to_u16, be)
    cmap.write_bytes(sub_offset, be)
  end
  # shared format-0 subtable : format(0), length(262), language(0), 256 ids
  cmap.write_bytes(0_u16, be)
  cmap.write_bytes(262_u16, be)
  cmap.write_bytes(0_u16, be)
  256.times { cmap.write_byte(0_u8) }
  cmap_bytes = cmap.to_slice

  io = IO::Memory.new
  io.write_bytes(0x00010000_u32, be) # sfnt version (TrueType)
  io.write_bytes(1_u16, be)          # numTables
  io.write_bytes(0_u16, be)          # searchRange
  io.write_bytes(0_u16, be)          # entrySelector
  io.write_bytes(0_u16, be)          # rangeShift
  io.write("cmap".to_slice)
  io.write_bytes(0_u32, be)                  # checksum
  io.write_bytes(28_u32, be)                 # offset (12 header + 16 record)
  io.write_bytes(cmap_bytes.size.to_u32, be) # length
  io.write(cmap_bytes)
  io.to_slice
end

# Builds a minimal sfnt TrueType program with head + hhea + maxp + hmtx
# tables, giving each glyph the supplied advance width (font units) and
# the supplied unitsPerEm. Enough for the § 6.2.11.5 width check.
private def truetype_program_with_metrics(advances : Array(Int32), units_per_em : Int32) : Bytes
  be = IO::ByteFormat::BigEndian
  num = advances.size

  head = IO::Memory.new
  head.write_bytes(1_u16, be)               # majorVersion
  head.write_bytes(0_u16, be)               # minorVersion
  head.write_bytes(0_u32, be)               # fontRevision
  head.write_bytes(0_u32, be)               # checkSumAdjustment
  head.write_bytes(0x5F0F3CF5_u32, be)      # magicNumber
  head.write_bytes(0_u16, be)               # flags
  head.write_bytes(units_per_em.to_u16, be) # unitsPerEm (offset 18)
  34.times { head.write_byte(0_u8) }        # created..glyphDataFormat → 54 total

  hhea = IO::Memory.new
  hhea.write_bytes(1_u16, be)        # majorVersion
  hhea.write_bytes(0_u16, be)        # minorVersion
  30.times { hhea.write_byte(0_u8) } # ascent..metricDataFormat
  hhea.write_bytes(num.to_u16, be)   # numberOfHMetrics (offset 34)

  maxp = IO::Memory.new
  maxp.write_bytes(0x00005000_u32, be) # version 0.5 (numGlyphs only)
  maxp.write_bytes(num.to_u16, be)     # numGlyphs

  hmtx = IO::Memory.new
  advances.each do |advance|
    hmtx.write_bytes(advance.to_u16, be) # advanceWidth
    hmtx.write_bytes(0_i16, be)          # leftSideBearing
  end

  tables = {"head" => head.to_slice, "hhea" => hhea.to_slice, "maxp" => maxp.to_slice, "hmtx" => hmtx.to_slice}
  io = IO::Memory.new
  io.write_bytes(0x00010000_u32, be)     # sfnt version
  io.write_bytes(tables.size.to_u16, be) # numTables
  io.write_bytes(0_u16, be)              # searchRange
  io.write_bytes(0_u16, be)              # entrySelector
  io.write_bytes(0_u16, be)              # rangeShift
  offset = 12 + tables.size * 16
  tables.each do |tag, bytes|
    io.write(tag.to_slice)
    io.write_bytes(0_u32, be) # checksum
    io.write_bytes(offset.to_u32, be)
    io.write_bytes(bytes.size.to_u32, be)
    offset += bytes.size
  end
  tables.each_value { |bytes| io.write(bytes) }
  io.to_slice
end

# A CIDFontType2 (Identity-H Type0 wrapper) embedding a program where
# every glyph advances 1000 units at unitsPerEm 1000 (→ width 1000),
# with the given /W array string.
private def pdf_with_cidfont_widths(declared_w : String) : Bytes
  program = truetype_program_with_metrics([1000, 1000], 1000)
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /Emb /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Emb " \
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " \
    "/CIDToGIDMap /Identity /FontDescriptor 6 0 R /W #{declared_w} >>",
    "<< /Type /FontDescriptor /FontName /Emb /FontFile2 7 0 R >>",
    {"<< /Length1 #{program.size} >>", program},
  ] of ObjBody)
end

# A page that strokes a path in an ICCBased CMYK colour space under an
# ExtGState with the given /OPM and /OP (stroke overprint) values.
private def pdf_with_overprint_cmyk(opm : Int32, op : String) : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R " \
    "/Resources << /ExtGState << /GS1 4 0 R >> /ColorSpace << /CS0 5 0 R >> >> >>",
    "<< /Type /ExtGState /OPM #{opm} /OP #{op} >>",
    "[ /ICCBased 7 0 R ]",
    {"<< >>", "/CS0 CS /GS1 gs 10 10 m 20 20 l S".to_slice},
    {"<< /N 4 >>", Bytes.new(8, 0_u8)},
  ] of ObjBody)
end

# A document with one /Type /EmbeddedFile stream carrying `content`,
# reachable from the catalog /Names /EmbeddedFiles name tree.
private def pdf_with_embedded_file(content : Bytes) : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R " \
    "/Names << /EmbeddedFiles << /Names [(data) 4 0 R] >> >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Filespec /F (data) /UF (data) /EF << /F 5 0 R >> >>",
    {"<< /Type /EmbeddedFile >>", content},
  ] of ObjBody)
end

# Builds a minimal JP2 byte stream : signature box + jp2h{ihdr, colr}.
# `bpc` is the raw BPC byte (depth-1, or 0xFF for varying) ; a colr box
# with METH=1 carries `enum_cs`.
private def jp2_bytes(nc : Int32, bpc : Int32, meth : Int32, approx : Int32, enum_cs : Int32) : Bytes
  be = IO::ByteFormat::BigEndian
  ihdr = IO::Memory.new
  ihdr.write_bytes(1_u32, be) # height
  ihdr.write_bytes(1_u32, be) # width
  ihdr.write_bytes(nc.to_u16, be)
  ihdr.write_byte(bpc.to_u8)
  ihdr.write_byte(7_u8) # C
  ihdr.write_byte(0_u8) # UnkC
  ihdr.write_byte(0_u8) # IPR
  colr = IO::Memory.new
  colr.write_byte(meth.to_u8)
  colr.write_byte(0_u8) # PREC
  colr.write_byte(approx.to_u8)
  colr.write_bytes(enum_cs.to_u32, be) if meth == 1

  write_jp2_box = ->(io : IO::Memory, type : String, body : Bytes) do
    io.write_bytes((8 + body.size).to_u32, be)
    io.write(type.to_slice)
    io.write(body)
  end
  jp2h = IO::Memory.new
  write_jp2_box.call(jp2h, "ihdr", ihdr.to_slice)
  write_jp2_box.call(jp2h, "colr", colr.to_slice)

  io = IO::Memory.new
  io.write_bytes(12_u32, be)
  io.write("jP  ".to_slice)
  io.write_bytes(0x0D0A870A_u32, be)
  write_jp2_box.call(io, "jp2h", jp2h.to_slice)
  io.to_slice
end

# A page with a /JPXDecode image XObject carrying the given JP2 data,
# optionally with a PDF /ColorSpace (which overrides the embedded one).
private def pdf_with_jpeg2000(jp2 : Bytes, color_space : Bool = false) : Bytes
  cs = color_space ? "/ColorSpace /DeviceRGB " : ""
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /XObject << /Im0 4 0 R >> >> >>",
    {"<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 #{cs}/Filter /JPXDecode >>", jp2},
  ] of ObjBody)
end

# A page whose content stream is `content`, using a Type0 Identity-H
# font backed by a 2-glyph CIDFontType2 program (CIDs 0 and 1 valid).
private def pdf_with_glyph_text(content : String) : Bytes
  program = truetype_program_with_metrics([1000, 1000], 1000)
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /Emb /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Emb " \
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " \
    "/CIDToGIDMap /Identity /FontDescriptor 6 0 R >>",
    "<< /Type /FontDescriptor /FontName /Emb /FontFile2 8 0 R >>",
    {"<< >>", content.to_slice},
    {"<< /Length1 #{program.size} >>", program},
  ] of ObjBody)
end

# A subset CIDFontType2 (2-glyph program, Identity map) whose
# FontDescriptor carries the given /CIDSet bitmap.
private def pdf_with_cidset(cidset : Bytes) : Bytes
  program = truetype_program_with_metrics([1000, 1000], 1000)
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Emb /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Emb " \
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " \
    "/CIDToGIDMap /Identity /FontDescriptor 6 0 R /W [0 [1000 1000]] >>",
    "<< /Type /FontDescriptor /FontName /ABCDEF+Emb /FontFile2 7 0 R /CIDSet 8 0 R >>",
    {"<< /Length1 #{program.size} >>", program},
    {"<< >>", cidset},
  ] of ObjBody)
end

# A simple TrueType font embedding the given program as /FontFile2, with
# the given FontDescriptor /Flags (4 = symbolic, 32 = non-symbolic).
private def pdf_with_truetype_program(records : Array(Tuple(Int32, Int32)), flags : Int32) : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /TrueType /BaseFont /Emb /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>",
    "<< /Type /FontDescriptor /FontName /Emb /Flags #{flags} /FontFile2 6 0 R >>",
    {"<< /Length1 #{truetype_program_with_cmap(records).size} >>", truetype_program_with_cmap(records)},
  ] of ObjBody)
end

# --- PDF/UA-1 structure-tree fixtures ---

# A Figure structure element with no /Alt or /ActualText (§ 7.3).
private def pdfua_figure_no_alt : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R] >>",
    "<< /Type /StructElem /S /Figure /P 4 0 R >>",
  ] of ObjBody)
end

# A Figure structure element carrying /Alt (conformant under § 7.3).
private def pdfua_figure_with_alt : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R] >>",
    "<< /Type /StructElem /S /Figure /P 4 0 R /Alt (A bar chart) >>",
  ] of ObjBody)
end

# A TH structure element whose parent is a Table, not a TR (§ 7.2).
private def pdfua_th_not_in_tr : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R] >>",
    "<< /Type /StructElem /S /Table /P 4 0 R /K [6 0 R] >>",
    "<< /Type /StructElem /S /TH /P 5 0 R >>",
  ] of ObjBody)
end

# A Note structure element with no /ID (§ 7.9).
private def pdfua_note_no_id : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R] >>",
    "<< /Type /StructElem /S /Note /P 4 0 R >>",
  ] of ObjBody)
end

# A structure tree mixing a weak heading (H) and a strong heading (H1)
# — violating § 7.4.4.
private def pdfua_mixed_headings : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Lang (fr) /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R 6 0 R] >>",
    "<< /Type /StructElem /S /H /P 4 0 R >>",
    "<< /Type /StructElem /S /H1 /P 4 0 R >>",
  ] of ObjBody)
end

# A section node with two child H tags — violating § 7.4.4 t1.
private def pdfua_two_child_h : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Lang (fr) /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R] >>",
    "<< /Type /StructElem /S /Sect /P 4 0 R /K [6 0 R 7 0 R] >>",
    "<< /Type /StructElem /S /H /P 5 0 R >>",
    "<< /Type /StructElem /S /H /P 5 0 R >>",
  ] of ObjBody)
end

# A Figure with /Alt but the document declares no /Lang anywhere —
# violating § 7.2 (language of Alt not determinable).
private def pdfua_alt_no_lang : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R] >>",
    "<< /Type /StructElem /S /Figure /P 4 0 R /Alt (a chart) >>",
  ] of ObjBody)
end

# A structure element with no /P (parent) entry (§ 7.1).
private def pdfua_struct_no_parent : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /StructTreeRoot /K [5 0 R] >>",
    "<< /Type /StructElem /S /P >>",
  ] of ObjBody)
end

# A Type0 font whose /Encoding names a CMap that is neither predefined
# (Table 118) nor embedded — violating § 6.2.11.3.3 t1.
private def pdf_with_nonpredefined_cmap : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding /Bogus-CMap-H /DescendantFonts [5 0 R] >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo " \
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /CIDToGIDMap /Identity >>",
  ] of ObjBody)
end

# A Type0 font with an embedded CMap whose dictionary /WMode (0) differs
# from the WMode declared in the stream content (1) — violating
# § 6.2.11.3.3 t2.
private def pdf_with_cmap_wmode_mismatch : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding 5 0 R /DescendantFonts [6 0 R] >>",
    {"<< /Type /CMap /CMapName /Custom /WMode 0 >>", "%!PS\n/WMode 1 def\nbegincmap\nendcmap\n".to_slice},
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo " \
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /CIDToGIDMap /Identity >>",
  ] of ObjBody)
end

# A CIDFontType2 with an embedded /FontFile2 but no /CIDToGIDMap,
# violating § 6.2.11.3.2.
private def pdf_with_cidfont_no_gidmap : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type0 /BaseFont /Foo /Encoding /Identity-H /DescendantFonts [5 0 R] >>",
    "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Foo /FontDescriptor 6 0 R >>",
    "<< /Type /FontDescriptor /FontName /Foo /FontFile2 7 0 R >>",
    {"<< >>", "fontdata".to_slice},
  ] of ObjBody)
end

# A file with a signature whose /ByteRange ([0 10 20 5]) does not
# reach end-of-file, violating § 6.4.3 (t1).
private def pdf_with_bad_signature : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /FT /Sig /T (Sig1) /V 5 0 R >>",
    "<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 10 20 5] /Contents <00> >>",
  ] of ObjBody)
end

# A file with an ICCBased colour space whose ICC profile declares an
# invalid "abst" device class, violating § 6.2.4.2.
private def pdf_with_bad_iccbased : Bytes
  icc = Bytes.new(132, 0_u8)
  icc[8] = 2_u8
  "abst".to_slice.each_with_index { |byte, i| icc[12 + i] = byte }
  "RGB ".to_slice.each_with_index { |byte, i| icc[16 + i] = byte }
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /ColorSpace << /CS0 [/ICCBased 4 0 R] >> >> >>",
    {"<< /N 3 >>", icc},
  ] of ObjBody)
end

# A file whose /AF-referenced file specification carries an embedded
# file (/EF) but lacks the /F and /UF name keys, violating § 6.8.
private def pdf_with_bad_filespec : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /AF [4 0 R] >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /Filespec /EF << /F 5 0 R >> >>",
    {"<< >>", "data".to_slice},
  ] of ObjBody)
end

# A file whose optional-content /D configuration has no /Name and a
# forbidden /AS key, violating § 6.9.
private def pdf_with_bad_ocg : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R " \
    "/OCProperties << /OCGs [4 0 R] /D << /AS [] >> >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /OCG /Name (Layer 1) >>",
  ] of ObjBody)
end

# An optional-content /D configuration whose /Order array lists only one
# of the file's two OCGs — violating § 6.9 t3 (Order must reference every
# OCG). /Name is present and there is no /AS, isolating the t3 defect.
private def pdf_with_incomplete_oc_order : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R " \
    "/OCProperties << /OCGs [4 0 R 5 0 R] " \
    "/D << /Name (Default) /Order [4 0 R] >> >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /OCG /Name (Layer 1) >>",
    "<< /Type /OCG /Name (Layer 2) >>",
  ] of ObjBody)
end

# An optional-content /D configuration whose /Order references both OCGs
# (a nested group array with a label) — complete, so § 6.9 t3 passes.
private def pdf_with_complete_oc_order : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R " \
    "/OCProperties << /OCGs [4 0 R 5 0 R] " \
    "/D << /Name (Default) /Order [4 0 R [(Group) 5 0 R]] >> >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /OCG /Name (Layer 1) >>",
    "<< /Type /OCG /Name (Layer 2) >>",
  ] of ObjBody)
end

# A catalog /Perms dictionary carrying a key other than /UR3 and
# /DocMDP — violating § 6.1.12 t1.
private def pdf_with_bad_permissions : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Perms << /UR3 4 0 R /Foo 4 0 R >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /SigRef /TransformMethod /UR3 >>",
  ] of ObjBody)
end

# A /Perms dictionary with /DocMDP whose signature reference dictionary
# carries a forbidden /DigestMethod — violating § 6.1.12 t2.
private def pdf_with_docmdp_digest : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Perms << /DocMDP 4 0 R >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /SigRef /TransformMethod /DocMDP /DigestMethod /MD5 >>",
  ] of ObjBody)
end

# A well-formed /Perms : only /UR3 and /DocMDP, and a signature
# reference dictionary with no Digest* keys — conformant under § 6.1.12.
private def pdf_with_clean_permissions : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Perms << /UR3 4 0 R /DocMDP 4 0 R >> >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    "<< /Type /SigRef /TransformMethod /DocMDP >>",
  ] of ObjBody)
end

# A page carrying a transparency group (/Group /S /Transparency) but no
# /CS blending colour space, with no PDF/A OutputIntent — violating
# § 6.2.10 t2.
private def pdf_with_transparency_no_group_cs : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Group << /S /Transparency >> >>",
  ] of ObjBody)
end

# A DeviceN colour space with a spot colorant (/SpotRed) and no
# /Colorants dictionary — violating § 6.2.4.4 t1.
private def pdf_with_devicen_no_colorants : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /ColorSpace << /CS0 4 0 R >> >> >>",
    "[ /DeviceN [ /SpotRed ] /DeviceRGB 5 0 R ]",
    "<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 0 0] /N 1 >>",
  ] of ObjBody)
end

# A DeviceN whose attributes dictionary lists the spot colorant in
# /Colorants — conformant under § 6.2.4.4 t1.
private def pdf_with_devicen_colorants : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /ColorSpace << /CS0 4 0 R >> >> >>",
    "[ /DeviceN [ /SpotRed ] /DeviceRGB 5 0 R << /Colorants << /SpotRed 6 0 R >> >> ]",
    "<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 0 0] /N 1 >>",
    "[ /Separation /SpotRed /DeviceRGB 5 0 R ]",
  ] of ObjBody)
end

# Two Separation colour spaces sharing the name /Spot but with
# different alternate spaces — violating § 6.2.4.4 t2.
private def pdf_with_inconsistent_separations : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Resources << /ColorSpace << /CS0 4 0 R /CS1 5 0 R >> >> >>",
    "[ /Separation /Spot /DeviceRGB 6 0 R ]",
    "[ /Separation /Spot /DeviceCMYK 7 0 R ]",
    "<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 0 0] /N 1 >>",
    "<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 0 0 0] /N 1 >>",
  ] of ObjBody)
end

# The same transparency page but with a /CS on its /Group — conformant
# under § 6.2.10 t2 even without an OutputIntent.
private def pdf_with_transparency_and_group_cs : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
    "/Group << /S /Transparency /CS /DeviceRGB >> >>",
  ] of ObjBody)
end

# Builds a valid "mntr"/RGB sRGB-like ICC profile header (≥ 132 bytes).
private def rgb_icc : Bytes
  icc = Bytes.new(132, 0_u8)
  icc[8] = 2_u8
  "mntr".to_slice.each_with_index { |byte, i| icc[12 + i] = byte }
  "RGB ".to_slice.each_with_index { |byte, i| icc[16 + i] = byte }
  icc
end

# A page with an RGB OutputIntent whose content stream sets DeviceCMYK
# (the `k` operator) — forbidden without a CMYK OutputIntent or
# DefaultCMYK (§ 6.2.4.3).
private def pdf_with_cmyk_in_content : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /OutputIntents [4 0 R] >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R >>",
    "<< /Type /OutputIntent /S /GTS_PDFA1 /DestOutputProfile 6 0 R >>",
    {"<< >>", "0 0 0 1 k 10 10 50 50 re f\n".to_slice},
    {"<< /N 3 >>", rgb_icc},
  ] of ObjBody)
end

# A page with an RGB OutputIntent whose content stream sets DeviceRGB
# (`rg`) and DeviceGray (`g`) — both anchored by the RGB OutputIntent,
# so § 6.2.4.3 must NOT fire.
private def pdf_with_rgb_gray_in_content : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /OutputIntents [4 0 R] >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R >>",
    "<< /Type /OutputIntent /S /GTS_PDFA1 /DestOutputProfile 6 0 R >>",
    {"<< >>", "1 0 0 rg 10 10 50 50 re f 0.5 g 70 70 30 30 re f\n".to_slice},
    {"<< /N 3 >>", rgb_icc},
  ] of ObjBody)
end

# A page whose content stream sets a non-standard rendering intent
# via the `ri` operator (`/Banana ri`), violating § 6.2.6.
private def pdf_with_bad_rendering_intent : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
    {"<< >>", "/Banana ri 10 10 50 50 re f\n".to_slice},
  ] of ObjBody)
end

# A page whose content stream uses an operator ("bananas") that
# ISO 32000-1 does not define, violating § 6.2.2.
private def pdf_with_bad_operator : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
    {"<< >>", "10 20 m 30 40 l S\nbananas\n".to_slice},
  ] of ObjBody)
end

# A page whose content uses a font (/F1 Tf) but that has no /Resources
# of its own — the Resources live on the parent /Pages node, so the
# name is inherited, violating § 6.2.2 t2.
private def pdf_with_inherited_resources : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 /Resources << /Font << /F1 5 0 R >> >> >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
    {"<< >>", "BT /F1 12 Tf (Hi) Tj ET".to_slice},
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ] of ObjBody)
end

# The same page but carrying its own /Resources — conformant under
# § 6.2.2 t2.
private def pdf_with_own_resources : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " \
    "/Resources << /Font << /F1 5 0 R >> >> >>",
    {"<< >>", "BT /F1 12 Tf (Hi) Tj ET".to_slice},
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ] of ObjBody)
end

# A classic cross-reference table with a doubled EOL between the `xref`
# keyword and its subsection header — violating § 6.1.4 t2. Built by
# inserting one extra LF after the first `xref\n` of a normal file
# (object offsets precede the table, so they stay valid).
private def pdf_with_bad_xref_eol : Bytes
  base = build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
  ] of ObjBody)
  needle = "xref\n".to_slice
  io = IO::Memory.new
  inserted = false
  i = 0
  while i < base.size
    if !inserted && i + needle.size <= base.size && base[i, needle.size] == needle
      io.write(needle)
      io.write_byte(0x0A_u8) # extra EOL marker → two between xref and header
      i += needle.size
      inserted = true
    else
      io.write_byte(base[i])
      i += 1
    end
  end
  io.to_slice
end

# A page whose content stream embeds an inline image using the LZW
# filter (/F /LZW) — forbidden by § 6.1.10.
private def pdf_with_inline_lzw_filter : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
    {"<< >>", "q BI /W 1 /H 1 /CS /G /BPC 8 /F /LZW ID \u{0}\u{0} EI Q".to_slice},
  ] of ObjBody)
end

# An inline image whose /Filter array contains LZW — also forbidden
# (§ 6.1.10), exercising the array-valued filter path.
private def pdf_with_inline_lzw_array : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
    {"<< >>", "q BI /W 1 /H 1 /CS /G /BPC 8 /Filter [/AHx /LZW] ID 00 EI Q".to_slice},
  ] of ObjBody)
end

# An inline image using the allowed Flate filter (/F /Fl) — conformant
# under § 6.1.10.
private def pdf_with_inline_flate_filter : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
    {"<< >>", "q BI /W 1 /H 1 /CS /G /BPC 8 /F /Fl ID \u{0}\u{0} EI Q".to_slice},
  ] of ObjBody)
end

# A file whose XMP packet header carries a forbidden `bytes` attribute
# (§ 6.6.2.1 t2) and declares an invalid conformance level (§ 6.6.4
# t3). The XML itself is well-formed so only those two rules fire.
private def pdf_with_bad_xmp : Bytes
  xmp = %(<?xpacket begin="" bytes="42"?>) +
        %(<x:xmpmeta xmlns:x="adobe:ns:meta/">) +
        %(<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">) +
        %(<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" ) +
        %(pdfaid:part="2" pdfaid:conformance="Z"/>) +
        %(</rdf:RDF></x:xmpmeta><?xpacket end="w"?>)
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    {"<< /Type /Metadata /Subtype /XML >>", xmp.to_slice},
  ] of ObjBody)
end

# A parseable file whose page has a degenerate MediaBox (1×1 unit),
# violating § 6.1.13 (t11 : boundaries must be ≥ 3 units).
private def pdf_with_implementation_limit_violation : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] >>",
  ] of ObjBody)
end

# A parseable file whose page dictionary carries an odd-length
# hexadecimal string, violating § 6.1.6.
private def pdf_with_hex_violation : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Custom <abc> >>",
  ] of ObjBody)
end

# A minimal file with no binary-marker comment after the header,
# violating § 6.1.2 (t2).
private def pdf_without_binary_comment : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
  ] of ObjBody, binary_comment: false)
end

# A well-formed file with extra bytes appended after the final %%EOF,
# violating § 6.1.3 (t3).
private def pdf_with_trailing_garbage : Bytes
  base = build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
  ] of ObjBody)
  io = IO::Memory.new
  io.write(base)
  io << "trailing junk\n"
  io.to_slice
end

# A conformant Text annotation : permitted subtype, /F with Print set
# and the forbidden bits clear, /AP containing only /N whose value is
# an appearance stream. Must trip none of the § 6.3 rules.
private def pdf_with_conformant_annotation : Bytes
  build_pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
    "<< /Type /Annot /Subtype /Text /Rect [0 0 100 100] /F 4 " \
    "/AP << /N 5 0 R >> >>",
    {"<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] >>", Bytes[0_u8]},
  ] of ObjBody)
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

  it "detects § 6.2.8 image-dictionary and § 6.2.6 rendering-intent violations" do
    report = PDF::Validate.bytes(pdf_with_image_violations, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should contain("pdfa2-6.2.8-image-dictionary-keys")
    failed.should contain("pdfa2-6.2.6-rendering-intent")
  end

  it "detects a non-conformant DestOutputProfile (§ 6.2.3, spac class)" do
    report = PDF::Validate.bytes(pdf_with_bad_output_intent, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should contain("pdfa2-6.2.3-output-intent-profile")
  end

  it "does not flag a clean document under the § 6.2 lot-2 rules" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.2.3-output-intent-profile")
    failed.should_not contain("pdfa2-6.2.6-rendering-intent")
    failed.should_not contain("pdfa2-6.2.8-image-dictionary-keys")
  end

  it "detects § 6.3 annotation violations (type, flags, appearance)" do
    report = PDF::Validate.bytes(pdf_with_annotation_violations, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should contain("pdfa2-6.3.1-annotation-types")
    failed.should contain("pdfa2-6.3.2-annotation-flags")
    failed.should contain("pdfa2-6.3.3-annotation-appearances")
  end

  it "does not flag a conformant annotation under the § 6.3 rules" do
    report = PDF::Validate.bytes(pdf_with_conformant_annotation, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.3.1-annotation-types")
    failed.should_not contain("pdfa2-6.3.2-annotation-flags")
    failed.should_not contain("pdfa2-6.3.3-annotation-appearances")
  end

  it "detects § 6.1.7 / § 6.10 / § 6.11 structural violations" do
    report = PDF::Validate.bytes(pdf_with_structure_violations, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should contain("pdfa2-6.1.7.1-no-external-streams")
    failed.should contain("pdfa2-6.1.7.2-stream-filters")
    failed.should contain("pdfa2-6.10-no-alternate-presentations")
    failed.should contain("pdfa2-6.11-no-requirements")
  end

  it "does not flag a clean document under the § 6.1/6.10/6.11 rules" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.1.7.1-no-external-streams")
    failed.should_not contain("pdfa2-6.1.7.2-stream-filters")
    failed.should_not contain("pdfa2-6.10-no-alternate-presentations")
    failed.should_not contain("pdfa2-6.11-no-requirements")
  end

  it "detects a missing binary-marker comment (§ 6.1.2)" do
    report = PDF::Validate.bytes(pdf_without_binary_comment, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.2-file-header")
  end

  it "detects data after the final %%EOF (§ 6.1.3)" do
    report = PDF::Validate.bytes(pdf_with_trailing_garbage, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.3-no-data-after-eof")
  end

  it "does not flag a well-formed header or EOF (§ 6.1.2/6.1.3)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.1.2-file-header")
    failed.should_not contain("pdfa2-6.1.3-no-data-after-eof")
  end

  it "detects an odd-length hexadecimal string (§ 6.1.6)" do
    report = PDF::Validate.bytes(pdf_with_hex_violation, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.6-hex-strings")
  end

  it "detects a degenerate page boundary (§ 6.1.13 t11)" do
    report = PDF::Validate.bytes(pdf_with_implementation_limit_violation, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.13-implementation-limits")
  end

  it "does not flag a clean document under § 6.1.13" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.1.13-implementation-limits")
  end

  it "detects forbidden XMP packet attributes and invalid conformance (§ 6.6)" do
    report = PDF::Validate.bytes(pdf_with_bad_xmp, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should contain("pdfa2-6.6.2.1-xmp-well-formed")
    failed.should contain("pdfa2-6.6.4-conformance-level")
  end

  it "does not flag a clean XMP packet (§ 6.6)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.6.2.1-xmp-well-formed")
    failed.should_not contain("pdfa2-6.6.4-conformance-level")
  end

  it "detects an undefined content-stream operator (§ 6.2.2)" do
    report = PDF::Validate.bytes(pdf_with_bad_operator, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.2-defined-operators")
  end

  it "does not flag a clean content stream (§ 6.2.2)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.2-defined-operators")
  end

  it "detects DeviceCMYK in a content stream under an RGB OutputIntent (§ 6.2.4.3)" do
    report = PDF::Validate.bytes(pdf_with_cmyk_in_content, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.4.3-content-device-colours")
  end

  it "allows DeviceRGB/DeviceGray content under an RGB OutputIntent (§ 6.2.4.3)" do
    report = PDF::Validate.bytes(pdf_with_rgb_gray_in_content, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.4.3-content-device-colours")
  end

  it "detects an invalid rendering intent set via the ri operator (§ 6.2.6)" do
    report = PDF::Validate.bytes(pdf_with_bad_rendering_intent, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.6-rendering-intent")
  end

  it "detects an embedded-file spec missing /F or /UF (§ 6.8)" do
    report = PDF::Validate.bytes(pdf_with_bad_filespec, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.8-embedded-filespec")
  end

  it "detects optional-content configuration issues (§ 6.9)" do
    report = PDF::Validate.bytes(pdf_with_bad_ocg, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.9-optional-content")
  end

  it "does not flag a clean document under § 6.8/6.9" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.8-embedded-filespec")
    failed.should_not contain("pdfa2-6.9-optional-content")
  end

  it "detects an /Order that omits an OCG (§ 6.9 t3)" do
    report = PDF::Validate.bytes(pdf_with_incomplete_oc_order, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.9-optional-content")
  end

  it "does not flag a complete /Order array (§ 6.9 t3)" do
    report = PDF::Validate.bytes(pdf_with_complete_oc_order, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.9-optional-content")
  end

  it "detects a DeviceN spot colorant without /Colorants (§ 6.2.4.4 t1)" do
    report = PDF::Validate.bytes(pdf_with_devicen_no_colorants, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.4.4-devicen-separation")
  end

  it "does not flag a DeviceN with a complete /Colorants (§ 6.2.4.4 t1)" do
    report = PDF::Validate.bytes(pdf_with_devicen_colorants, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.4.4-devicen-separation")
  end

  it "detects inconsistent Separations sharing one name (§ 6.2.4.4 t2)" do
    report = PDF::Validate.bytes(pdf_with_inconsistent_separations, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.4.4-devicen-separation")
  end

  it "does not flag a document without DeviceN/Separation (§ 6.2.4.4)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.4.4-devicen-separation")
  end

  it "detects a transparency page without a /Group /CS (§ 6.2.10 t2)" do
    report = PDF::Validate.bytes(pdf_with_transparency_no_group_cs, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.10-page-transparency-group")
  end

  it "does not flag a transparency page that has a /Group /CS (§ 6.2.10 t2)" do
    report = PDF::Validate.bytes(pdf_with_transparency_and_group_cs, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.10-page-transparency-group")
  end

  it "does not flag transparency when a PDF/A OutputIntent is present (§ 6.2.10 t2)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.10-page-transparency-group")
  end

  it "detects a permissions dictionary with a forbidden key (§ 6.1.12 t1)" do
    report = PDF::Validate.bytes(pdf_with_bad_permissions, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.12-permissions-dictionary")
  end

  it "detects Digest* keys in a DocMDP signature reference (§ 6.1.12 t2)" do
    report = PDF::Validate.bytes(pdf_with_docmdp_digest, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.12-permissions-dictionary")
  end

  it "does not flag a well-formed permissions dictionary (§ 6.1.12)" do
    report = PDF::Validate.bytes(pdf_with_clean_permissions, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.1.12-permissions-dictionary")
  end

  it "does not flag a document without a permissions dictionary (§ 6.1.12)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.1.12-permissions-dictionary")
  end

  it "detects a content stream relying on inherited Resources (§ 6.2.2 t2)" do
    report = PDF::Validate.bytes(pdf_with_inherited_resources, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.2-resources-associated")
  end

  it "does not flag a page with its own Resources (§ 6.2.2 t2)" do
    report = PDF::Validate.bytes(pdf_with_own_resources, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.2-resources-associated")
  end

  it "detects a doubled EOL after the xref keyword (§ 6.1.4 t2)" do
    report = PDF::Validate.bytes(pdf_with_bad_xref_eol, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.4-xref-eol")
  end

  it "does not flag a single EOL after the xref keyword (§ 6.1.4 t2)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.1.4-xref-eol")
  end

  it "detects an inline image using the LZW filter (§ 6.1.10)" do
    report = PDF::Validate.bytes(pdf_with_inline_lzw_filter, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.10-inline-image-filter")
  end

  it "detects LZW in an inline image /Filter array (§ 6.1.10)" do
    report = PDF::Validate.bytes(pdf_with_inline_lzw_array, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.1.10-inline-image-filter")
  end

  it "does not flag an inline image using Flate (§ 6.1.10)" do
    report = PDF::Validate.bytes(pdf_with_inline_flate_filter, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.1.10-inline-image-filter")
  end

  it "does not flag a document without inline images (§ 6.1.10)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.1.10-inline-image-filter")
  end

  it "detects interactive-form action violations (§ 6.4.1)" do
    report = PDF::Validate.bytes(pdf_with_form_violations, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.4.1-interactive-forms")
  end

  it "detects /XFA and /NeedsRendering (§ 6.4.2)" do
    report = PDF::Validate.bytes(pdf_with_form_violations, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.4.2-no-dynamic-forms")
  end

  it "detects an invalid ICCBased profile (§ 6.2.4.2)" do
    report = PDF::Validate.bytes(pdf_with_bad_iccbased, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.4.2-iccbased-profile")
  end

  it "does not flag a clean document under § 6.4 / § 6.2.4.2" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.4.1-interactive-forms")
    failed.should_not contain("pdfa2-6.4.2-no-dynamic-forms")
    failed.should_not contain("pdfa2-6.2.4.2-iccbased-profile")
  end

  it "detects a signature whose /ByteRange does not cover the document (§ 6.4.3)" do
    report = PDF::Validate.bytes(pdf_with_bad_signature, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.4.3-signature-byterange")
  end

  it "detects a font dictionary missing /BaseFont (§ 6.2.11.2)" do
    report = PDF::Validate.bytes(pdf_with_bad_font, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.2-font-dictionary")
  end

  it "detects a CIDFontType2 without /CIDToGIDMap (§ 6.2.11.3.2)" do
    report = PDF::Validate.bytes(pdf_with_cidfont_no_gidmap, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.3.2-cidtogidmap")
  end

  it "detects a Type0 CMap whose CIDSystemInfo mismatches the CIDFont (§ 6.2.11.3.1)" do
    report = PDF::Validate.bytes(pdf_with_mismatched_cidsysteminfo, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.3.1-type0-encoding")
  end

  it "does not flag an Identity-H Type0 font (§ 6.2.11.3.1)" do
    report = PDF::Validate.bytes(pdf_with_identity_type0, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.3.1-type0-encoding")
  end

  it "detects a non-symbolic TrueType without MacRoman/WinAnsi (§ 6.2.11.6 t2)" do
    report = PDF::Validate.bytes(pdf_with_bad_truetype_encoding, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.6-truetype-encoding")
  end

  it "detects a symbolic TrueType carrying an /Encoding (§ 6.2.11.6 t3)" do
    report = PDF::Validate.bytes(pdf_with_symbolic_truetype_encoding, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.6-truetype-encoding")
  end

  it "does not flag a WinAnsi non-symbolic TrueType (§ 6.2.11.6)" do
    report = PDF::Validate.bytes(pdf_with_good_truetype_encoding, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.6-truetype-encoding")
  end

  it "detects a symbolic TrueType program cmap with >1 subtable and no (3,0) (§ 6.2.11.6 t4)" do
    report = PDF::Validate.bytes(pdf_with_truetype_program([{1, 0}, {0, 3}], 4), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.6-truetype-cmap")
  end

  it "does not flag a symbolic TrueType program cmap with a (3,0) subtable (§ 6.2.11.6 t4)" do
    report = PDF::Validate.bytes(pdf_with_truetype_program([{3, 0}], 4), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.6-truetype-cmap")
  end

  it "detects a non-symbolic TrueType program with only a (3,0) cmap (§ 6.2.11.6 t1)" do
    report = PDF::Validate.bytes(pdf_with_truetype_program([{3, 0}], 32), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.6-truetype-cmap")
  end

  it "does not flag a non-symbolic TrueType program with a (3,1) cmap (§ 6.2.11.6 t1)" do
    report = PDF::Validate.bytes(pdf_with_truetype_program([{3, 1}], 32), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.6-truetype-cmap")
  end

  it "detects a CIDFontType2 /W width inconsistent with the program (§ 6.2.11.5)" do
    report = PDF::Validate.bytes(pdf_with_cidfont_widths("[1 [500]]"), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.5-cidfont-widths")
  end

  it "does not flag a CIDFontType2 /W width matching the program (§ 6.2.11.5)" do
    report = PDF::Validate.bytes(pdf_with_cidfont_widths("[1 [1000]]"), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.5-cidfont-widths")
  end

  it "detects a /CIDSet that omits a present CID (§ 6.2.11.4.2)" do
    report = PDF::Validate.bytes(pdf_with_cidset(Bytes[0x80_u8]), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.4.2-cidset")
  end

  it "does not flag a /CIDSet that marks all present CIDs (§ 6.2.11.4.2)" do
    report = PDF::Validate.bytes(pdf_with_cidset(Bytes[0xC0_u8]), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.4.2-cidset")
  end

  it "detects text referencing a glyph absent from the program (§ 6.2.11.4.1 t2)" do
    report = PDF::Validate.bytes(pdf_with_glyph_text("BT /F1 12 Tf <0005> Tj ET"), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.4.1-glyphs-present")
  end

  it "detects text referencing the .notdef glyph (§ 6.2.11.8)" do
    report = PDF::Validate.bytes(pdf_with_glyph_text("BT /F1 12 Tf <0000> Tj ET"), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.8-notdef")
  end

  it "does not flag text showing a present, non-notdef glyph (§ 6.2.11.4.1/§ 6.2.11.8)" do
    report = PDF::Validate.bytes(pdf_with_glyph_text("BT /F1 12 Tf <0001> Tj ET"), "pdf-a-2b")
    ids = report.failures.map(&.rule.id)
    ids.should_not contain("pdfa2-6.2.11.4.1-glyphs-present")
    ids.should_not contain("pdfa2-6.2.11.8-notdef")
  end

  it "exempts invisible text (rendering mode 3) from the .notdef check (§ 6.2.11.8)" do
    report = PDF::Validate.bytes(pdf_with_glyph_text("BT /F1 12 Tf 3 Tr <0000> Tj ET"), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.8-notdef")
  end

  it "does not flag a conformant JPEG2000 image (§ 6.2.8.3)" do
    jp2 = jp2_bytes(nc: 3, bpc: 7, meth: 1, approx: 1, enum_cs: 16)
    report = PDF::Validate.bytes(pdf_with_jpeg2000(jp2), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.8.3-jpeg2000")
  end

  it "detects a JPEG2000 image with an invalid channel count (§ 6.2.8.3 t1)" do
    jp2 = jp2_bytes(nc: 5, bpc: 7, meth: 1, approx: 1, enum_cs: 16)
    report = PDF::Validate.bytes(pdf_with_jpeg2000(jp2), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.8.3-jpeg2000")
  end

  it "detects a JPEG2000 image using CIEJab (EnumCS 19) (§ 6.2.8.3 t4)" do
    jp2 = jp2_bytes(nc: 3, bpc: 7, meth: 1, approx: 1, enum_cs: 19)
    report = PDF::Validate.bytes(pdf_with_jpeg2000(jp2), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.8.3-jpeg2000")
  end

  it "exempts JPEG2000 colour-space checks when a PDF /ColorSpace is present (§ 6.2.8.3)" do
    jp2 = jp2_bytes(nc: 3, bpc: 7, meth: 1, approx: 1, enum_cs: 19)
    report = PDF::Validate.bytes(pdf_with_jpeg2000(jp2, color_space: true), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.8.3-jpeg2000")
  end

  it "detects a JPEG2000 image with an out-of-range bit depth (§ 6.2.8.3 t5)" do
    jp2 = jp2_bytes(nc: 3, bpc: 39, meth: 1, approx: 1, enum_cs: 16) # depth 40
    report = PDF::Validate.bytes(pdf_with_jpeg2000(jp2), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.8.3-jpeg2000")
  end

  it "detects an embedded file that is not a PDF/A (§ 6.8 t5)" do
    report = PDF::Validate.bytes(pdf_with_embedded_file("not a pdf at all".to_slice), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.8-embedded-pdfa")
  end

  it "does not flag an embedded conformant PDF/A file (§ 6.8 t5)" do
    path = "#{__DIR__}/fixtures/ghostscript_pdfa2b.pdf"
    pending! "fixture missing" unless File.exists?(path)
    embedded = File.read(path).to_slice
    report = PDF::Validate.bytes(pdf_with_embedded_file(embedded), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.8-embedded-pdfa")
  end

  it "detects ICCBased CMYK painted with overprint and OPM=1 (§ 6.2.4.2 t2)" do
    report = PDF::Validate.bytes(pdf_with_overprint_cmyk(1, "true"), "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.4.2-overprint-cmyk")
  end

  it "does not flag ICCBased CMYK overprint when OPM=0 (§ 6.2.4.2 t2)" do
    report = PDF::Validate.bytes(pdf_with_overprint_cmyk(0, "true"), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.4.2-overprint-cmyk")
  end

  it "does not flag ICCBased CMYK with OPM=1 but no overprint (§ 6.2.4.2 t2)" do
    report = PDF::Validate.bytes(pdf_with_overprint_cmyk(1, "false"), "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.4.2-overprint-cmyk")
  end

  it "detects a non-predefined, non-embedded CMap name (§ 6.2.11.3.3 t1)" do
    report = PDF::Validate.bytes(pdf_with_nonpredefined_cmap, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.3.3-cmap-restrictions")
  end

  it "detects an embedded CMap WMode mismatch (§ 6.2.11.3.3 t2)" do
    report = PDF::Validate.bytes(pdf_with_cmap_wmode_mismatch, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.2.11.3.3-cmap-restrictions")
  end

  it "does not flag an Identity-H CMap (§ 6.2.11.3.3)" do
    report = PDF::Validate.bytes(pdf_with_identity_type0, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.2.11.3.3-cmap-restrictions")
  end

  it "does not flag a clean document under § 6.2.11" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.2.11.2-font-dictionary")
    failed.should_not contain("pdfa2-6.2.11.3.2-cidtogidmap")
  end

  it "does not flag a document without signatures (§ 6.4.3)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.4.3-signature-byterange")
  end

  it "detects an invalid XMP extension schema (§ 6.6.2.3)" do
    report = PDF::Validate.bytes(pdf_with_invalid_extension_schema, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.6.2.3-extension-schema")
  end

  it "does not flag a document with no extension schema (§ 6.6.2.3)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.6.2.3-extension-schema")
  end

  it "detects an XMP property in an undeclared namespace (§ 6.6.2.3.1)" do
    report = PDF::Validate.bytes(pdf_with_undeclared_xmp_property, "pdf-a-2b")
    report.failures.map(&.rule.id).should contain("pdfa2-6.6.2.3.1-property-schemas")
  end

  it "does not flag a property declared by an extension schema (§ 6.6.2.3.1)" do
    report = PDF::Validate.bytes(pdf_with_declared_xmp_property, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.6.2.3.1-property-schemas")
  end

  it "does not flag predefined-schema XMP properties (§ 6.6.2.3.1)" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    report.failures.map(&.rule.id).should_not contain("pdfa2-6.6.2.3.1-property-schemas")
  end

  it "does not flag a clean document under the byte-level § 6.1 rules" do
    report = PDF::Validate.bytes(pdfa_bytes, "pdf-a-2b")
    failed = report.failures.map(&.rule.id)
    failed.should_not contain("pdfa2-6.1.6-hex-strings")
    failed.should_not contain("pdfa2-6.1.7.1-stream-eol")
    failed.should_not contain("pdfa2-6.1.9-indirect-spacing")
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
    # The per-element rules must not fire on a clean tagged document
    # (every StructElem has /P ; no Figure/Note/table cells).
    ids = report.failures.map(&.rule.id)
    ids.should_not contain("pdfua1-7.1-struct-parent")
    ids.should_not contain("pdfua1-7.3-figure-alt")
    ids.should_not contain("pdfua1-7.2-table-cells")
    ids.should_not contain("pdfua1-7.9-note-id")
    ids.should_not contain("pdfua1-7.4.4-heading-structure")
    ids.should_not contain("pdfua1-7.2-attribute-language")
  end

  it "flags a Figure without /Alt or /ActualText (§ 7.3)" do
    report = PDF::Validate.bytes(pdfua_figure_no_alt, "pdf-ua-1")
    report.failures.map(&.rule.id).should contain("pdfua1-7.3-figure-alt")
  end

  it "does not flag a Figure carrying /Alt (§ 7.3)" do
    report = PDF::Validate.bytes(pdfua_figure_with_alt, "pdf-ua-1")
    report.failures.map(&.rule.id).should_not contain("pdfua1-7.3-figure-alt")
  end

  it "flags a TH outside a TR (§ 7.2)" do
    report = PDF::Validate.bytes(pdfua_th_not_in_tr, "pdf-ua-1")
    report.failures.map(&.rule.id).should contain("pdfua1-7.2-table-cells")
  end

  it "flags a Note without an /ID (§ 7.9)" do
    report = PDF::Validate.bytes(pdfua_note_no_id, "pdf-ua-1")
    report.failures.map(&.rule.id).should contain("pdfua1-7.9-note-id")
  end

  it "flags a structure element without /P (§ 7.1)" do
    report = PDF::Validate.bytes(pdfua_struct_no_parent, "pdf-ua-1")
    report.failures.map(&.rule.id).should contain("pdfua1-7.1-struct-parent")
  end

  it "flags a document mixing weak and strong headings (§ 7.4.4)" do
    report = PDF::Validate.bytes(pdfua_mixed_headings, "pdf-ua-1")
    report.failures.map(&.rule.id).should contain("pdfua1-7.4.4-heading-structure")
  end

  it "flags a node with two child H tags (§ 7.4.4 t1)" do
    report = PDF::Validate.bytes(pdfua_two_child_h, "pdf-ua-1")
    report.failures.map(&.rule.id).should contain("pdfua1-7.4.4-heading-structure")
  end

  it "flags an /Alt with no determinable language (§ 7.2)" do
    report = PDF::Validate.bytes(pdfua_alt_no_lang, "pdf-ua-1")
    report.failures.map(&.rule.id).should contain("pdfua1-7.2-attribute-language")
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

describe PDF::Validate::ByteScanner do
  it "flags an odd-length hexadecimal string (§ 6.1.6 t1)" do
    scan = PDF::Validate::ByteScanner.new("<abc>".to_slice).scan
    scan.hex_string_violations.should_not be_empty
  end

  it "flags a non-hex character in a hexadecimal string (§ 6.1.6 t2)" do
    scan = PDF::Validate::ByteScanner.new("<12zz>".to_slice).scan
    scan.hex_string_violations.any?(&.includes?("non-hex")).should be_true
  end

  it "accepts a well-formed hex string and ignores << dictionary >>" do
    scan = PDF::Validate::ByteScanner.new("<< /K <4142> >>".to_slice).scan
    scan.hex_string_violations.should be_empty
  end

  it "flags a lone CR after the stream keyword (§ 6.1.7.1 t2)" do
    scan = PDF::Validate::ByteScanner.new(
      "1 0 obj<<>>stream\rdata\nendstream\n".to_slice).scan
    scan.stream_eol_violations.should_not be_empty
  end

  it "accepts an LF after the stream keyword" do
    scan = PDF::Validate::ByteScanner.new(
      "1 0 obj<<>>stream\ndata\nendstream\n".to_slice).scan
    scan.stream_eol_violations.should be_empty
  end

  it "flags double-space indirect spacing (§ 6.1.9)" do
    scan = PDF::Validate::ByteScanner.new("1  0 obj\n".to_slice).scan
    scan.indirect_spacing_violations.should_not be_empty
  end

  it "accepts single-space indirect objects and references" do
    scan = PDF::Validate::ByteScanner.new("12 0 obj\n[1 0 R]\n".to_slice).scan
    scan.indirect_spacing_violations.should be_empty
  end

  it "does not tokenise inside literal strings" do
    scan = PDF::Validate::ByteScanner.new("(a <abc> 1  0 R)\n".to_slice).scan
    scan.hex_string_violations.should be_empty
    scan.indirect_spacing_violations.should be_empty
  end
end

describe PDF::Validate::ContentStreamScanner do
  it "accepts defined operators and skips operands" do
    scan = PDF::Validate::ContentStreamScanner.new("BT /F1 12 Tf (hello) Tj ET".to_slice).scan
    scan.undefined_operators.should be_empty
  end

  it "flags an undefined operator" do
    scan = PDF::Validate::ContentStreamScanner.new("10 20 foo".to_slice).scan
    scan.undefined_operators.should contain("foo")
  end

  it "ignores boolean/null operand keywords" do
    scan = PDF::Validate::ContentStreamScanner.new("true false null /X gs".to_slice).scan
    scan.undefined_operators.should be_empty
  end

  it "tracks the maximum q/Q nesting depth" do
    scan = PDF::Validate::ContentStreamScanner.new("q q q Q Q Q".to_slice).scan
    scan.max_q_depth.should eq(3)
  end

  it "does not tokenise inside literal strings" do
    scan = PDF::Validate::ContentStreamScanner.new("(q q badop) Tj".to_slice).scan
    scan.undefined_operators.should be_empty
    scan.max_q_depth.should eq(0)
  end

  it "skips inline-image data between ID and EI" do
    scan = PDF::Validate::ContentStreamScanner.new("BI /W 2 /H 2 ID zzdataz EI Q".to_slice).scan
    scan.undefined_operators.should be_empty
  end

  it "records the device colour spaces set by rg/k/g operators" do
    scan = PDF::Validate::ContentStreamScanner.new("1 0 0 rg 0.5 g 0 0 0 1 k".to_slice).scan
    scan.device_colour_spaces.should contain("RGB")
    scan.device_colour_spaces.should contain("GRAY")
    scan.device_colour_spaces.should contain("CMYK")
  end

  it "flags a non-standard rendering intent passed to ri" do
    scan = PDF::Validate::ContentStreamScanner.new("/Banana ri".to_slice).scan
    scan.invalid_rendering_intents.should contain("Banana")
  end

  it "accepts a standard rendering intent passed to ri" do
    scan = PDF::Validate::ContentStreamScanner.new("/Perceptual ri".to_slice).scan
    scan.invalid_rendering_intents.should be_empty
  end
end

describe PDF::Validate::XmpExtensionSchema do
  it "accepts a well-formed extension schema (matches veraPDF)" do
    PDF::Validate::XmpExtensionSchema.new(VALID_EXTENSION_XMP).validate.violations.should be_empty
  end

  it "flags a missing pdfaSchema:prefix (§ 6.6.2.3.3 t4)" do
    xmp = VALID_EXTENSION_XMP.gsub(/<pdfaSchema:prefix>[^<]*<\/pdfaSchema:prefix>/, "")
    violations = PDF::Validate::XmpExtensionSchema.new(xmp).validate.violations
    violations.any?(&.includes?("t4")).should be_true
  end

  it "flags an invalid property category (§ 6.6.2.3.3 t9)" do
    xmp = VALID_EXTENSION_XMP.gsub("internal", "bogus")
    violations = PDF::Validate::XmpExtensionSchema.new(xmp).validate.violations
    violations.any?(&.includes?("t9")).should be_true
  end

  it "flags an undefined extension-schema field (§ 6.6.2.3.2)" do
    xmp = VALID_EXTENSION_XMP.gsub(
      "<pdfaSchema:prefix>custom</pdfaSchema:prefix>",
      "<pdfaSchema:prefix>custom</pdfaSchema:prefix><pdfaSchema:bogusField>x</pdfaSchema:bogusField>")
    violations = PDF::Validate::XmpExtensionSchema.new(xmp).validate.violations
    violations.any?(&.includes?("6.6.2.3.2")).should be_true
  end

  it "reports nothing when there is no extension schema" do
    PDF::Validate::XmpExtensionSchema.new("<x>no extension here</x>").validate.violations.should be_empty
  end
end
