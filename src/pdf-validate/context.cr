module PDF
  module Validate
    # The parsed view of a PDF that checks evaluate against. Wraps a
    # `PDF::Reader` and lazily exposes the structures the rule
    # vocabulary needs : the document catalog, the trailer, and the
    # XMP metadata text.
    class Context
      getter reader : PDF::Reader

      def initialize(@reader : PDF::Reader)
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
