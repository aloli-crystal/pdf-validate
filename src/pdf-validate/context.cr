module PDF
  module Validate
    # The parsed view of a PDF that checks evaluate against. Wraps a
    # `PDF::Reader` and lazily exposes the structures the rule
    # vocabulary needs : the document catalog, the trailer, and the
    # XMP metadata text.
    class Context
      getter reader : PDF::Reader

      # The raw file bytes, when available (set by `PDF::Validate.bytes`
      # / `.file`). Needed by the byte-level structure rules ; `nil`
      # when validating an already-open reader, in which case those
      # rules report no violation rather than guess.
      @raw : Bytes?

      def initialize(@reader : PDF::Reader, @raw : Bytes? = nil)
      end

      # The document catalog (trailer /Root, resolved).
      getter catalog : PDF::Objects::Dictionary do
        root = @reader.trailer["Root"]?
        raise "PDF has no /Root in trailer" unless root
        resolved = @reader.resolve(root)
        resolved.as?(PDF::Objects::Dictionary) ||
          raise "/Root does not resolve to a dictionary"
      end

      # The trailer dictionary.
      def trailer : PDF::Objects::Dictionary
        @reader.trailer
      end

      # The XMP metadata as text (empty string if the document has no
      # /Metadata stream). XMP is stored uncompressed, so the decoded
      # bytes are the XML.
      getter xmp : String do
        meta = catalog["Metadata"]?
        return "" unless meta
        stream = @reader.resolve(meta).as?(PDF::Objects::Stream)
        return "" unless stream
        String.new(stream.encoded_data)
      end

      # Resolves `obj` through indirect references via the reader.
      def resolve(obj : PDF::Objects::Base) : PDF::Objects::Base
        @reader.resolve(obj)
      end

      # Names of fonts whose glyph program is NOT embedded. PDF/A
      # requires every font to be embedded (ISO 19005-2 § 6.3.4-5) ;
      # veraPDF flags the standard-14 Type1 fonts and any descriptor
      # lacking a FontFile/FontFile2/FontFile3.
      #
      # Walks every Font object :
      # * Type0 wrappers are skipped — their descendant CIDFont
      #   carries the FontDescriptor and is checked directly.
      # * Type3 fonts are embedded by construction (glyphs are content
      #   streams) → never flagged.
      # * Type1 / TrueType / CIDFontType0 / CIDFontType2 must have a
      #   FontDescriptor with one of FontFile, FontFile2, FontFile3.
      getter non_embedded_fonts : Array(String) do
        result = [] of String
        each_font_dict do |dict|
          subtype = dict["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf)
          next if subtype == "/Type0" # composite wrapper — descendant visited too
          next if subtype == "/Type3" # glyphs are content streams

          base = dict["BaseFont"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) || "(unnamed)"

          fd = dict["FontDescriptor"]?
          unless fd
            result << base # simple font with no descriptor = standard-14, not embedded
            next
          end
          descriptor = resolve(fd).as?(PDF::Objects::Dictionary)
          unless descriptor
            result << base
            next
          end
          embedded = descriptor.has_key?("FontFile") ||
                     descriptor.has_key?("FontFile2") ||
                     descriptor.has_key?("FontFile3")
          result << base unless embedded
        end
        result.uniq
      end

      # Walks the whole object graph from the catalog, resolving
      # references (with cycle protection), and yields every reachable
      # object. `reader.objects` is a lazy cache that does not hold
      # every object, so a graph traversal is the robust way to
      # enumerate them. This is the shared primitive every
      # graph-scanning check builds on.
      def each_object(&)
        visited = Set(UInt64).new
        stack = [catalog.as(PDF::Objects::Base)]
        until stack.empty?
          obj = stack.pop
          obj = resolve(obj) if obj.is_a?(PDF::Objects::Reference)
          next unless visited.add?(obj.object_id)

          yield obj

          case obj
          when PDF::Objects::Dictionary
            obj.each { |_k, v| stack << v }
          when PDF::Objects::Stream
            obj.dictionary.each { |_k, v| stack << v }
          when PDF::Objects::Array
            obj.each { |e| stack << e }
          end
        end
      end

      # The blend modes ISO 32000-1 defines ; any other value in an
      # ExtGState /BM is forbidden in PDF/A (ISO 19005-2 § 6.2.10).
      STANDARD_BLEND_MODES = %w[
        Normal Compatible Multiply Screen Overlay Darken Lighten
        ColorDodge ColorBurn HardLight SoftLight Difference Exclusion
        Hue Saturation Color Luminosity
      ]

      # ExtGState transfer/halftone violations (ISO 19005-2 § 6.2.5) :
      # an ExtGState dictionary shall not contain /TR or /HTP, and /TR2
      # only with the value /Default.
      getter extgstate_transfer_violations : Array(String) do
        issues = [] of String
        each_extgstate do |gstate|
          issues << "/TR present" if gstate.has_key?("TR")
          issues << "/HTP present" if gstate.has_key?("HTP")
          if tr2 = gstate["TR2"]?
            name = tr2.as?(PDF::Objects::Name).try(&.to_pdf)
            issues << "/TR2 = #{name || "<non-name>"} (only /Default allowed)" unless name == "/Default"
          end
        end
        issues.uniq
      end

      # Non-standard blend modes found in any ExtGState /BM
      # (ISO 19005-2 § 6.2.10, test 1). /BM may be a name or an array
      # of names ; every entry must be a standard blend mode.
      getter nonstandard_blend_modes : Array(String) do
        bad = [] of String
        each_extgstate do |gstate|
          bm = gstate["BM"]?
          next unless bm
          names = case bm
                  when PDF::Objects::Name  then [bm.value]
                  when PDF::Objects::Array then bm.compact_map(&.as?(PDF::Objects::Name).try(&.value))
                  else                          [] of String
                  end
          names.each do |mode|
            bad << "/#{mode}" unless STANDARD_BLEND_MODES.includes?(mode)
          end
        end
        bad.uniq
      end

      # Forbidden XObject constructs (ISO 19005-2 § 6.2.9) : PostScript
      # XObjects (`/Subtype /PS` or form `/Subtype2 /PS` / `/PS` key),
      # reference XObjects (`/Ref`), and `/OPI`.
      getter forbidden_xobject_violations : Array(String) do
        issues = [] of String
        each_object do |obj|
          d = obj.as?(PDF::Objects::Dictionary) ||
              obj.as?(PDF::Objects::Stream).try(&.dictionary)
          next unless d
          next unless d["Type"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/XObject"
          sub = d["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf)
          issues << "PostScript XObject (/Subtype /PS)" if sub == "/PS"
          if sub == "/Form"
            sub2 = d["Subtype2"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf)
            issues << "form XObject with /Subtype2 /PS" if sub2 == "/PS"
            issues << "form XObject with /PS key" if d.has_key?("PS")
            issues << "reference XObject (/Ref)" if d.has_key?("Ref")
            issues << "form XObject with /OPI" if d.has_key?("OPI")
          end
        end
        issues.uniq
      end

      # The four rendering intents ISO 32000-1 defines (Table 70). Any
      # other value for an image /Intent (or a content-stream `ri`
      # operator, not reached here) is forbidden (ISO 19005-2 § 6.2.6).
      RENDERING_INTENTS = %w[
        AbsoluteColorimetric RelativeColorimetric Perceptual Saturation
      ]

      # Image XObject dictionary violations (ISO 19005-2 § 6.2.8) :
      # no /Alternates (t1) ; no /OPI (t2) ; /Interpolate, if present,
      # must be false (t3) ; for a non-mask image /BitsPerComponent, if
      # present, must be 1/2/4/8/16 (t4) ; for an image mask it must be
      # 1 (t5).
      getter image_dictionary_violations : Array(String) do
        issues = [] of String
        idx = 0
        each_object do |obj|
          stream = obj.as?(PDF::Objects::Stream)
          next unless stream
          dict = stream.dictionary
          next unless dict["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/Image"
          idx += 1
          label = "image##{idx}"
          mask = dict["ImageMask"]?.try(&.as?(PDF::Objects::Boolean)).try(&.value) == true
          issues << "#{label}: /Alternates present" if dict.has_key?("Alternates")
          issues << "#{label}: /OPI present" if dict.has_key?("OPI")
          if interp = dict["Interpolate"]?.try(&.as?(PDF::Objects::Boolean))
            issues << "#{label}: /Interpolate must be false" if interp.value
          end
          if bpc = dict["BitsPerComponent"]?.try(&.as?(PDF::Objects::Number)).try(&.to_i64)
            if mask
              issues << "#{label}: image-mask /BitsPerComponent must be 1 (got #{bpc})" unless bpc == 1
            elsif ![1_i64, 2, 4, 8, 16].includes?(bpc)
              issues << "#{label}: /BitsPerComponent must be 1/2/4/8/16 (got #{bpc})"
            end
          end
        end
        issues
      end

      # Non-standard rendering intents declared on image XObjects via
      # the /Intent key (ISO 19005-2 § 6.2.6). The content-stream `ri`
      # operator form is not reached by a dictionary walk — documented
      # as partial coverage in the gap analysis.
      getter invalid_rendering_intents : Array(String) do
        bad = [] of String
        each_object do |obj|
          dict = obj.as?(PDF::Objects::Stream).try(&.dictionary)
          next unless dict
          next unless dict["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/Image"
          intent = dict["Intent"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
          next unless intent
          bad << "/#{intent}" unless RENDERING_INTENTS.includes?(intent)
        end
        bad.uniq
      end

      # OutputIntent / DestOutputProfile violations (ISO 19005-2
      # § 6.2.3). The ICC profile that is the DestOutputProfile stream
      # must be an output ("prtr") or display ("mntr") profile in an
      # RGB/CMYK/GRAY colour space, ICC version < 5 (t1) ; when several
      # OutputIntents exist they must share one indirect profile (t2) ;
      # a PDF/X output intent must not carry /DestOutputProfileRef (t3).
      #
      # The ICC header is read from the DECODED stream bytes (the
      # reader inverts FlateDecode on parse) : device class at offset
      # 12, colour space at offset 16, major version at offset 8.
      getter output_intent_profile_violations : Array(String) do
        issues = [] of String
        oi = catalog["OutputIntents"]?
        return issues unless oi
        arr = resolve(oi).as?(PDF::Objects::Array)
        return issues unless arr

        dest_refs = [] of PDF::Objects::Reference
        arr.each do |entry|
          intent = resolve(entry).as?(PDF::Objects::Dictionary)
          next unless intent

          subtype = intent["S"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf)
          if subtype == "/GTS_PDFX" && intent.has_key?("DestOutputProfileRef")
            issues << "PDF/X output intent carries forbidden /DestOutputProfileRef"
          end

          dop = intent["DestOutputProfile"]?
          next unless dop
          dest_refs << dop if dop.is_a?(PDF::Objects::Reference)

          stream = resolve(dop).as?(PDF::Objects::Stream)
          next unless stream && stream.decoded
          icc = stream.encoded_data
          next unless icc.size >= 20
          cls = String.new(icc[12, 4])
          space = String.new(icc[16, 4])
          major = icc[8]
          unless cls == "prtr" || cls == "mntr"
            issues << "DestOutputProfile device class #{cls.inspect} (must be prtr/mntr)"
          end
          unless ["RGB ", "CMYK", "GRAY"].includes?(space)
            issues << "DestOutputProfile colour space #{space.inspect} (must be RGB/CMYK/GRAY)"
          end
          issues << "DestOutputProfile ICC major version #{major} (must be < 5)" if major >= 5
        end

        if arr.size > 1 && (dest_refs.size != arr.size || dest_refs.uniq.size > 1)
          issues << "multiple OutputIntents must share one indirect DestOutputProfile"
        end
        issues.uniq
      end

      # File-header violations (ISO 19005-2 § 6.1.2), read from the raw
      # bytes : the file shall begin at byte 0 with "%PDF-1.n"
      # (n in 0..7) followed by an EOL (t1), and the next line shall be
      # a comment "%" followed by at least four bytes > 127 — the
      # binary marker that flags the file as binary to transfer tools
      # (t2). Empty (no violation) when the raw bytes are unavailable.
      getter file_header_violations : Array(String) do
        issues = [] of String
        raw = @raw
        return issues unless raw

        unless raw.size >= 8 && String.new(raw[0, 7]) == "%PDF-1." &&
               raw[7] >= '0'.ord.to_u8 && raw[7] <= '7'.ord.to_u8
          issues << "file does not begin with %PDF-1.n (n in 0..7) at byte 0"
          return issues
        end

        # Skip to the end of the header line, then over its EOL.
        idx = 8
        while idx < raw.size && raw[idx] != 0x0A && raw[idx] != 0x0D
          idx += 1
        end
        idx += 1 if idx < raw.size && raw[idx] == 0x0D
        idx += 1 if idx < raw.size && raw[idx] == 0x0A

        if idx >= raw.size || raw[idx] != 0x25 # '%'
          issues << "missing binary-marker comment line after the header (§ 6.1.2 t2)"
        elsif idx + 4 >= raw.size || !four_high_bytes?(raw, idx + 1)
          issues << "binary-marker comment must be followed by ≥ 4 bytes > 127 (§ 6.1.2 t2)"
        end
        issues
      end

      # Trailing-data violation (ISO 19005-2 § 6.1.3, t3) : nothing
      # shall follow the final %%EOF marker except a single optional
      # EOL. Empty when raw bytes are unavailable or no %%EOF is found
      # (other rules cover a missing marker).
      getter data_after_eof_violations : Array(String) do
        issues = [] of String
        raw = @raw
        return issues unless raw
        eof = last_eof_offset(raw)
        return issues unless eof
        rest = raw[eof + 5, raw.size - (eof + 5)]
        allowed = rest.size == 0 ||
                  (rest.size == 1 && (rest[0] == 0x0A || rest[0] == 0x0D)) ||
                  (rest.size == 2 && rest[0] == 0x0D && rest[1] == 0x0A)
        issues << "#{rest.size} byte(s) after the final %%EOF" unless allowed
        issues
      end

      # `true` if the four bytes starting at `from` are all > 127.
      private def four_high_bytes?(raw : Bytes, from : Int32) : Bool
        offset = from
        while offset < from + 4
          return false if raw[offset] <= 127
          offset += 1
        end
        true
      end

      # Byte offset of the last "%%EOF" marker, or nil if none.
      private def last_eof_offset(raw : Bytes) : Int32?
        marker = "%%EOF".to_slice
        idx = raw.size - marker.size
        while idx >= 0
          return idx if raw[idx, marker.size] == marker
          idx -= 1
        end
        nil
      end

      # Stream filters PDF/A-2 permits (ISO 19005-2 § 6.1.7.2,
      # referencing ISO 32000-1 Table 6). LZWDecode is notably
      # forbidden ; any filter outside this list is a violation.
      ALLOWED_STREAM_FILTERS = %w[
        ASCIIHexDecode ASCII85Decode FlateDecode RunLengthDecode
        CCITTFaxDecode DCTDecode JBIG2Decode JPXDecode Crypt
      ]

      # Stream /Filter values that are not on the permitted list
      # (ISO 19005-2 § 6.1.7.2). /Filter may be a name or an array of
      # names.
      getter forbidden_stream_filters : Array(String) do
        bad = [] of String
        each_object do |obj|
          stream = obj.as?(PDF::Objects::Stream)
          next unless stream
          filter = stream.dictionary["Filter"]?.try { |ref| resolve(ref) }
          next unless filter
          names = case filter
                  when PDF::Objects::Name  then [filter.value]
                  when PDF::Objects::Array then filter.compact_map(&.as?(PDF::Objects::Name).try(&.value))
                  else                          [] of String
                  end
          names.each { |fname| bad << "/#{fname}" unless ALLOWED_STREAM_FILTERS.includes?(fname) }
        end
        bad.uniq
      end

      # Streams that reference an external file (ISO 19005-2 § 6.1.7.1,
      # t3) : a stream dictionary shall not contain /F, /FFilter or
      # /FDecodeParms.
      getter external_stream_file_violations : Array(String) do
        issues = [] of String
        each_object do |obj|
          stream = obj.as?(PDF::Objects::Stream)
          next unless stream
          dict = stream.dictionary
          issues << "stream /F (external file)" if dict.has_key?("F")
          issues << "stream /FFilter" if dict.has_key?("FFilter")
          issues << "stream /FDecodeParms" if dict.has_key?("FDecodeParms")
        end
        issues.uniq
      end

      # Alternate-presentation constructs forbidden by PDF/A-2 :
      # /AlternatePresentations in the document /Names dictionary
      # (ISO 19005-2 § 6.10, t1) and /PresSteps in any Page
      # (§ 6.10, t2).
      getter alternate_presentation_violations : Array(String) do
        issues = [] of String
        if names = catalog["Names"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
          issues << "/Names /AlternatePresentations present" if names.has_key?("AlternatePresentations")
        end
        each_page do |page|
          issues << "page /PresSteps present" if page.has_key?("PresSteps")
        end
        issues.uniq
      end

      # Annotation subtypes ISO 32000-1 defines and PDF/A-2 permits
      # (ISO 19005-2 § 6.3.1). 3D/Sound/Screen/Movie and any undefined
      # subtype are forbidden.
      ANNOTATION_SUBTYPES = %w[
        Text Link FreeText Line Square Circle Polygon PolyLine Highlight
        Underline Squiggly StrikeOut Stamp Caret Ink Popup FileAttachment
        Widget PrinterMark TrapNet Watermark Redact
      ]

      # Annotation subtypes that are not on the permitted list
      # (ISO 19005-2 § 6.3.1).
      getter forbidden_annotation_types : Array(String) do
        bad = [] of String
        each_annotation do |annot|
          sub = annot["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
          next unless sub
          bad << "/#{sub}" unless ANNOTATION_SUBTYPES.includes?(sub)
        end
        bad.uniq
      end

      # Annotation /F flag violations (ISO 19005-2 § 6.3.2) : every
      # annotation except Popup must carry /F (t1) ; if present, the
      # Print bit (4) must be set and Invisible (1), Hidden (2),
      # NoView (32) and ToggleNoView (256) must be clear (t2).
      getter annotation_flag_violations : Array(String) do
        issues = [] of String
        each_annotation do |annot|
          sub = annot["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
          flags = annot["F"]?.try(&.as?(PDF::Objects::Number)).try(&.to_i64)
          if flags.nil?
            issues << "annotation /#{sub || "?"} is missing /F flags" unless sub == "Popup"
            next
          end
          issues << "annotation /#{sub} /F Print bit not set" if (flags & 4) == 0
          issues << "annotation /#{sub} /F Invisible bit set" if (flags & 1) != 0
          issues << "annotation /#{sub} /F Hidden bit set" if (flags & 2) != 0
          issues << "annotation /#{sub} /F NoView bit set" if (flags & 32) != 0
          issues << "annotation /#{sub} /F ToggleNoView bit set" if (flags & 256) != 0
        end
        issues.uniq
      end

      # Annotation appearance violations (ISO 19005-2 § 6.3.3) : an
      # appearance dictionary (/AP) is required except for a degenerate
      # Rect (width == height == 0), Popup or Link (t1) ; /AP shall
      # contain only the /N key (t2) ; for a Widget whose field type is
      # Btn, /N shall be an appearance subdictionary (t3), otherwise /N
      # shall be an appearance stream (t4).
      getter annotation_appearance_violations : Array(String) do
        issues = [] of String
        each_annotation do |annot|
          sub = annot["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
          ap = annot["AP"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Dictionary)

          unless ap || sub == "Popup" || sub == "Link" || annotation_rect_degenerate?(annot)
            issues << "annotation /#{sub || "?"} has no appearance (/AP)"
            next
          end
          next unless ap

          extra = ap.keys.map(&.value).reject { |key| key == "N" }
          issues << "annotation /#{sub} /AP has keys other than /N (#{extra.join(", ")})" unless extra.empty?

          appearance = ap["N"]?.try { |obj| resolve(obj) }
          next unless appearance
          if sub == "Widget" && annotation_field_type(annot) == "Btn"
            issues << "Widget/Btn /N must be an appearance subdictionary" unless appearance.is_a?(PDF::Objects::Dictionary)
          else
            issues << "annotation /#{sub} /N must be an appearance stream" unless appearance.is_a?(PDF::Objects::Stream)
          end
        end
        issues.uniq
      end

      # `true` if the annotation's /Rect is degenerate (zero width and
      # height) — such annotations are exempt from the appearance
      # requirement (ISO 19005-2 § 6.3.3, t1).
      private def annotation_rect_degenerate?(annot : PDF::Objects::Dictionary) : Bool
        rect = annot["Rect"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Array)
        return false unless rect && rect.size == 4
        coords = [] of Float64
        rect.each do |elem|
          num = resolve(elem).as?(PDF::Objects::Number)
          return false unless num
          coords << num.to_f64
        end
        (coords[2] - coords[0]) == 0 && (coords[3] - coords[1]) == 0
      end

      # Resolves an annotation's field type (/FT), following the
      # /Parent chain (AcroForm field hierarchy) since a Widget may
      # inherit it. Bounded to avoid cycles.
      private def annotation_field_type(annot : PDF::Objects::Dictionary) : String?
        node = annot
        4.times do
          if ft = node["FT"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
            return ft
          end
          parent = node["Parent"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Dictionary)
          return nil unless parent
          node = parent
        end
        nil
      end

      # Yields every `/Type /Page` dictionary, walking the page tree
      # from the catalog /Pages node (cycle-protected).
      private def each_page(&)
        root = catalog["Pages"]?
        return unless root
        visited = Set(UInt64).new
        stack = [resolve(root)]
        until stack.empty?
          node = stack.pop
          dict = node.as?(PDF::Objects::Dictionary)
          next unless dict
          next unless visited.add?(dict.object_id)
          if dict["Type"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/Page"
            yield dict
          elsif kids = dict["Kids"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Array)
            kids.each { |kid| stack << resolve(kid) }
          end
        end
      end

      # Yields every annotation dictionary reachable from a page's
      # /Annots array.
      private def each_annotation(&)
        each_page do |page|
          annots = page["Annots"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Array)
          next unless annots
          annots.each do |entry|
            annot = resolve(entry).as?(PDF::Objects::Dictionary)
            yield annot if annot
          end
        end
      end

      # Yields every `/Type /ExtGState` dictionary reachable.
      private def each_extgstate(&)
        each_object do |obj|
          d = obj.as?(PDF::Objects::Dictionary)
          next unless d
          if d["Type"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/ExtGState"
            yield d
          end
        end
      end

      # Yields every `/Type /Font` dictionary reachable from the
      # catalog.
      private def each_font_dict(&)
        each_object do |obj|
          dict = obj.as?(PDF::Objects::Dictionary)
          next unless dict
          if dict["Type"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/Font"
            yield dict
          end
        end
      end

      # `true` if any JavaScript action is reachable in the document —
      # a dictionary whose `/S` is `/JavaScript`, or a `/JavaScript`
      # entry under the catalog `/Names` name tree. PDF/A forbids all
      # JavaScript (ISO 19005-2 § 6.6.1).
      getter? has_javascript : Bool do
        # /Names /JavaScript name tree present?
        if names = catalog["Names"]?
          nd = resolve(names).as?(PDF::Objects::Dictionary)
          return true if nd && nd.has_key?("JavaScript")
        end
        result = false
        each_object do |obj|
          dict = obj.as?(PDF::Objects::Dictionary)
          next unless dict
          if dict["S"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/JavaScript"
            result = true
          end
        end
        result
      end

      # Names of image XObjects whose colour space is an uncalibrated
      # DeviceRGB / DeviceCMYK while the document declares no output
      # intent that could anchor them (ISO 19005-2 § 6.2.4). DeviceGray
      # is always allowed. A conservative check : only flags image
      # XObjects (the clearest case), not content-stream operators.
      getter uncalibrated_image_colorspaces : Array(String) do
        has_output_intent = catalog.has_key?("OutputIntents")
        flagged = [] of String
        return flagged if has_output_intent # an output intent anchors device spaces

        idx = 0
        each_object do |obj|
          stream = obj.as?(PDF::Objects::Stream)
          next unless stream
          d = stream.dictionary
          next unless d["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.to_pdf) == "/Image"
          cs = d["ColorSpace"]?.try { |space| resolve(space) }
          name = cs.try(&.as?(PDF::Objects::Name)).try(&.to_pdf)
          if name == "/DeviceRGB" || name == "/DeviceCMYK"
            idx += 1
            flagged << "image##{idx} #{name}"
          end
        end
        flagged
      end
    end
  end
end
