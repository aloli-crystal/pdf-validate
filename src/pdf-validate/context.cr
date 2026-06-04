require "xml"

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

      # XMP metadata stream violations (ISO 19005-2 § 6.6.2.1) : the
      # XMP packet header (<?xpacket …?>) shall not carry a `bytes`
      # (t2) or `encoding` (t3) attribute, and the packet shall be
      # well-formed XML (t4). Empty when there is no XMP (its absence
      # is covered by the presence rule).
      getter xmp_metadata_violations : Array(String) do
        issues = [] of String
        text = xmp
        return issues if text.empty?

        if header = text.match(/<\?xpacket\b[^>]*\?>/)
          issues << "XMP packet header uses the forbidden 'bytes' attribute" if header[0].includes?("bytes=")
          issues << "XMP packet header uses the forbidden 'encoding' attribute" if header[0].includes?("encoding=")
        end

        begin
          errors = XML.parse(text).errors
          issues << "XMP is not well-formed XML" if errors && !errors.empty?
        rescue
          issues << "XMP is not well-formed XML"
        end
        issues
      end

      # pdfaid:conformance value violations (ISO 19005-2 § 6.6.4, t3) :
      # if present, the conformance level shall be A, B or U. Matches
      # both the element (<pdfaid:conformance>B</…>) and attribute
      # (pdfaid:conformance="B") RDF serialisations.
      getter pdfaid_conformance_violations : Array(String) do
        issues = [] of String
        if matched = xmp.match(/pdfaid:conformance\s*(?:>\s*([^<\s]+)|=\s*["']([^"']+)["'])/)
          value = (matched[1]? || matched[2]?).try(&.strip)
          if value && !["A", "B", "U"].includes?(value)
            issues << "pdfaid:conformance is #{value.inspect} (must be A, B or U)"
          end
        end
        issues
      end

      # PDF/A extension-schema structure violations in the XMP
      # (ISO 19005-2 § 6.6.2.3, parsed by `XmpExtensionSchema`).
      getter xmp_extension_schema_violations : Array(String) do
        XmpExtensionSchema.new(xmp).validate.violations
      end

      # Font subtypes ISO 32000-1 defines (§ 6.2.11.2 t2), the simple
      # (single-byte) subtypes, and the FontFile3 subtypes PDF/A allows
      # (§ 6.2.11.2 t7).
      VALID_FONT_SUBTYPES      = %w[Type1 MMType1 TrueType Type3 Type0 CIDFontType0 CIDFontType2]
      SIMPLE_FONT_SUBTYPES     = %w[Type1 MMType1 TrueType]
      VALID_FONTFILE3_SUBTYPES = %w[Type1C CIDFontType0C OpenType]

      # The predefined CMaps of ISO 32000-1:2008, 9.7.5.2, Table 118 —
      # the only CMaps a PDF/A-2 file may name without embedding
      # (ISO 19005-2 § 6.2.11.3.3). Any other CMap must be an embedded
      # stream.
      PREDEFINED_CMAPS = %w[
        Identity-H Identity-V
        GB-EUC-H GB-EUC-V GBpc-EUC-H GBpc-EUC-V GBK-EUC-H GBK-EUC-V
        GBKp-EUC-H GBKp-EUC-V GBK2K-H GBK2K-V UniGB-UCS2-H UniGB-UCS2-V
        UniGB-UTF16-H UniGB-UTF16-V
        B5pc-H B5pc-V HKscs-B5-H HKscs-B5-V ETen-B5-H ETen-B5-V
        ETenms-B5-H ETenms-B5-V CNS-EUC-H CNS-EUC-V UniCNS-UCS2-H
        UniCNS-UCS2-V UniCNS-UTF16-H UniCNS-UTF16-V
        83pv-RKSJ-H 90ms-RKSJ-H 90ms-RKSJ-V 90msp-RKSJ-H 90msp-RKSJ-V
        90pv-RKSJ-H Add-RKSJ-H Add-RKSJ-V EUC-H EUC-V Ext-RKSJ-H
        Ext-RKSJ-V H V UniJIS-UCS2-H UniJIS-UCS2-V UniJIS-UCS2-HW-H
        UniJIS-UCS2-HW-V UniJIS-UTF16-H UniJIS-UTF16-V
        KSC-EUC-H KSC-EUC-V KSCms-UHC-H KSCms-UHC-V KSCms-UHC-HW-H
        KSCms-UHC-HW-V KSCpc-EUC-H UniKS-UCS2-H UniKS-UCS2-V
        UniKS-UTF16-H UniKS-UTF16-V
      ]

      # Font-dictionary violations (ISO 19005-2 § 6.2.11.2), checkable
      # from the dictionaries (no font program needed) : /Subtype is a
      # defined type (t2) ; /BaseFont is present except for Type3 (t3) ;
      # a non-standard simple font carries /FirstChar (t4), /LastChar
      # (t5) and a /Widths array of the right length (t6) ; a /FontFile3
      # has an allowed /Subtype (t7).
      getter font_dictionary_violations : Array(String) do
        issues = [] of String
        each_font_dict do |dict|
          subtype = dict["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
          unless subtype && VALID_FONT_SUBTYPES.includes?(subtype)
            issues << "font /Subtype #{subtype.inspect} is not an ISO 32000-1 font type (t2)"
            next
          end
          base = dict["BaseFont"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
          issues << "font missing /BaseFont (t3)" if subtype != "Type3" && base.nil?
          label = base || "(unnamed)"

          descriptor = dict["FontDescriptor"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)

          if SIMPLE_FONT_SUBTYPES.includes?(subtype) && descriptor
            # An embedded simple font is not a standard-14 font, so it
            # must declare its character range and widths.
            issues << "simple font #{label} missing /FirstChar (t4)" unless dict.has_key?("FirstChar")
            issues << "simple font #{label} missing /LastChar (t5)" unless dict.has_key?("LastChar")
            first = dict["FirstChar"]?.try(&.as?(PDF::Objects::Number)).try(&.to_i64)
            last = dict["LastChar"]?.try(&.as?(PDF::Objects::Number)).try(&.to_i64)
            widths = dict["Widths"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
            if widths.nil?
              issues << "simple font #{label} missing /Widths (t6)"
            elsif first && last && widths.size != (last - first + 1)
              issues << "simple font #{label} /Widths length ≠ LastChar-FirstChar+1 (t6)"
            end
          end

          if descriptor && (ff3 = descriptor["FontFile3"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Stream))
            ff3_subtype = ff3.dictionary["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value)
            if ff3_subtype && !VALID_FONTFILE3_SUBTYPES.includes?(ff3_subtype)
              issues << "font #{label} /FontFile3 /Subtype #{ff3_subtype.inspect} invalid (t7)"
            end
          end
        end
        issues.uniq
      end

      # Type0 font encoding violations (ISO 19005-2 § 6.2.11.3.1) : the
      # CMap must be Identity-H/V, or its /CIDSystemInfo (Registry +
      # Ordering) must match the descendant CIDFont's. Predefined named
      # CMaps other than Identity are accepted conservatively (their
      # registry/ordering would need the CMap tables).
      getter type0_encoding_violations : Array(String) do
        issues = [] of String
        each_font_dict do |dict|
          next unless dict["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value) == "Type0"
          encoding = dict["Encoding"]?.try { |ref| resolve(ref) }
          name = encoding.as?(PDF::Objects::Name).try(&.value)
          next if name == "Identity-H" || name == "Identity-V"
          cmap_stream = encoding.as?(PDF::Objects::Stream)
          next unless cmap_stream

          cmap_info = registry_ordering(cmap_stream.dictionary["CIDSystemInfo"]?)
          cidfont = descendant_cidfont(dict)
          next unless cidfont
          font_info = registry_ordering(cidfont["CIDSystemInfo"]?)
          next unless cmap_info && font_info
          unless cmap_info == font_info
            issues << "Type0 CMap CIDSystemInfo #{cmap_info} does not match the CIDFont #{font_info}"
          end
        end
        issues.uniq
      end

      # CMap restrictions (ISO 19005-2 § 6.2.11.3.3) for Type0 fonts :
      #   t1 — /Encoding is a predefined CMap name (Table 118) or an
      #        embedded CMap stream ; any other name is forbidden.
      #   t2 — for an embedded CMap, the /WMode in the CMap dictionary
      #        equals the WMode declared in the CMap stream content.
      #   t3 — a CMap's /UseCMap may reference only a predefined CMap.
      getter cmap_violations : Array(String) do
        issues = [] of String
        each_font_dict do |dict|
          next unless dict["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value) == "Type0"
          encoding = dict["Encoding"]?.try { |ref| resolve(ref) }
          next unless encoding

          if name = encoding.as?(PDF::Objects::Name).try(&.value)
            unless PREDEFINED_CMAPS.includes?(name)
              issues << "Type0 /Encoding names CMap /#{name}, which is neither predefined nor embedded"
            end
            next
          end

          stream = encoding.as?(PDF::Objects::Stream)
          next unless stream
          cmap_dict = stream.dictionary

          dict_wmode = cmap_dict["WMode"]?.try(&.as?(PDF::Objects::Number)).try(&.to_i64)
          stream_wmode = cmap_stream_wmode(stream)
          if dict_wmode && stream_wmode && dict_wmode != stream_wmode
            issues << "embedded CMap /WMode #{dict_wmode} differs from the stream's WMode #{stream_wmode}"
          end

          if use = cmap_dict["UseCMap"]?.try { |ref| resolve(ref) }
            use_name = use.as?(PDF::Objects::Name).try(&.value)
            if use_name && !PREDEFINED_CMAPS.includes?(use_name)
              issues << "embedded CMap /UseCMap references non-predefined CMap /#{use_name}"
            end
          end
        end
        issues.uniq
      end

      # The WMode integer declared inside a CMap stream's content
      # (`/WMode n def`), or nil if absent/unreadable.
      private def cmap_stream_wmode(stream : PDF::Objects::Stream) : Int64?
        return nil unless stream.decoded
        text = String.new(stream.encoded_data)
        if md = text.match(/\/WMode\s+(\d+)\s+def/)
          md[1].to_i64
        end
      end

      # The descendant CIDFont of a Type0 font (/DescendantFonts[0]).
      private def descendant_cidfont(type0 : PDF::Objects::Dictionary) : PDF::Objects::Dictionary?
        list = type0["DescendantFonts"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
        return nil if list.nil? || list.empty?
        resolve(list[0]).as?(PDF::Objects::Dictionary)
      end

      # The {Registry, Ordering} pair of a /CIDSystemInfo value, or nil.
      private def registry_ordering(value : PDF::Objects::Base?) : Tuple(String, String)?
        return nil unless value
        info = resolve(value).as?(PDF::Objects::Dictionary)
        return nil unless info
        registry = info["Registry"]?.try(&.as?(PDF::Objects::Str)).try(&.value)
        ordering = info["Ordering"]?.try(&.as?(PDF::Objects::Str)).try(&.value)
        return nil unless registry && ordering
        {registry, ordering}
      end

      # CIDFontType2 CIDToGIDMap violations (ISO 19005-2 § 6.2.11.3.2) :
      # a CIDFontType2 with an embedded program must carry /CIDToGIDMap.
      getter cidfont_gidmap_violations : Array(String) do
        issues = [] of String
        each_font_dict do |dict|
          next unless dict["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value) == "CIDFontType2"
          descriptor = dict["FontDescriptor"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
          next unless descriptor && descriptor.has_key?("FontFile2")
          unless dict.has_key?("CIDToGIDMap")
            base = dict["BaseFont"]?.try(&.as?(PDF::Objects::Name)).try(&.value) || "(unnamed)"
            issues << "CIDFontType2 #{base} with embedded program missing /CIDToGIDMap"
          end
        end
        issues.uniq
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

      # Pages that contain transparency must carry a /Group whose value
      # is a transparency group attribute dictionary with a /CS blending
      # colour space — unless the document declares a PDF/A OutputIntent
      # (ISO 19005-2 § 6.2.10, test 2). veraPDF short-circuits this test
      # to a pass as soon as the output intent's colour space is known
      # (`gOutputCS != null`), because that colour space then anchors the
      # blending space ; we do the same. The check therefore only bites a
      # document with *no* PDF/A output intent at all.
      getter page_transparency_group_violations : Array(String) do
        issues = [] of String
        # gOutputCS != null : an output intent anchors the blending space.
        return issues if catalog.has_key?("OutputIntents")

        index = 0
        each_page do |page|
          index += 1
          next unless page_contains_transparency?(page)
          group = page["Group"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Dictionary)
          next if group && group.has_key?("CS")
          issues << "page ##{index} contains transparency but its /Group has no /CS " \
                    "blending colour space (and no PDF/A OutputIntent is present)"
        end
        issues
      end

      # Standard process colorant names plus the two reserved names
      # (ISO 32000-1 § 8.6.6.4) — these never require a /Colorants entry.
      PROCESS_COLORANTS = %w[Cyan Magenta Yellow Black None All]

      # DeviceN / Separation violations (ISO 19005-2 § 6.2.4.4) :
      #   t1 — every *spot* colorant of a DeviceN/NChannel colour space
      #        (a name that is neither a standard process colorant nor
      #        listed in the attributes' /Process /Components) must have
      #        an entry in the attributes' /Colorants dictionary.
      #   t2 — all Separation colour spaces sharing one colorant name
      #        must share the same alternate space and tint transform.
      getter devicen_separation_violations : Array(String) do
        issues = [] of String
        seen = {} of String => Tuple(String, UInt64)
        each_object do |obj|
          arr = obj.as?(PDF::Objects::Array)
          next unless arr && arr.size >= 2
          case resolve(arr[0]).as?(PDF::Objects::Name).try(&.value)
          when "DeviceN", "NChannel"
            issues.concat(devicen_colorant_issues(arr))
          when "Separation"
            separation_consistency_issue(arr, seen).try { |msg| issues << msg }
          end
        end
        issues.uniq
      end

      # Spot colorants of a DeviceN/NChannel array that lack a /Colorants
      # entry (ISO 19005-2 § 6.2.4.4 t1).
      private def devicen_colorant_issues(arr : PDF::Objects::Array) : Array(String)
        issues = [] of String
        names = resolve(arr[1]).as?(PDF::Objects::Array)
        return issues unless names
        attrs = arr.size >= 5 ? resolve(arr[4]).as?(PDF::Objects::Dictionary) : nil
        colorants = attrs.try { |dict| dict["Colorants"]? }.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
        process = attrs.try { |dict| dict["Process"]? }.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
        comps = process.try { |dict| dict["Components"]? }.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
        process_names = comps.try(&.compact_map { |comp| resolve(comp).as?(PDF::Objects::Name).try(&.value) }) || [] of String

        names.each do |entry|
          cname = resolve(entry).as?(PDF::Objects::Name).try(&.value)
          next unless cname
          next if PROCESS_COLORANTS.includes?(cname) || process_names.includes?(cname)
          unless colorants && colorants.has_key?(cname)
            issues << "DeviceN spot colorant /#{cname} has no entry in the /Colorants dictionary"
          end
        end
        issues
      end

      # Records a Separation's {alternate, tint} signature under its
      # colorant name ; returns a message when a later Separation of the
      # same name disagrees (ISO 19005-2 § 6.2.4.4 t2).
      private def separation_consistency_issue(arr : PDF::Objects::Array, seen : Hash(String, Tuple(String, UInt64))) : String?
        return nil unless arr.size >= 4
        cname = resolve(arr[1]).as?(PDF::Objects::Name).try(&.value)
        return nil unless cname
        signature = {colour_space_signature(arr[2]), resolve(arr[3]).object_id}
        if prev = seen[cname]?
          return "Separation /#{cname} has inconsistent alternate space or tint transform across the file" if prev != signature
        else
          seen[cname] = signature
        end
        nil
      end

      # A stable signature for an alternate colour space : its name when
      # a device space, otherwise the resolved object identity.
      private def colour_space_signature(space : PDF::Objects::Base) : String
        resolved = resolve(space)
        resolved.as?(PDF::Objects::Name).try(&.value) || resolved.object_id.to_s
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

      # Non-standard rendering intents (ISO 19005-2 § 6.2.6), from both
      # serialisations : the /Intent key on image XObjects and the `ri`
      # operator in page content streams.
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
        bad.concat(content_scan[:invalid_ri].map { |name| "/#{name}" })
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

      # Colour space of the document's PDF/A OutputIntent, read from the
      # first DestOutputProfile ICC header ("RGB", "CMYK" or "GRAY"), or
      # nil if there is no usable output intent. This is veraPDF's
      # `gOutputCS`, the anchor for the § 6.2.4.3 device-colour rules.
      getter output_intent_colour_space : String? do
        oi = catalog["OutputIntents"]?
        return nil unless oi
        arr = resolve(oi).as?(PDF::Objects::Array)
        return nil unless arr
        arr.each do |entry|
          intent = resolve(entry).as?(PDF::Objects::Dictionary)
          next unless intent
          dop = intent["DestOutputProfile"]?
          next unless dop
          stream = resolve(dop).as?(PDF::Objects::Stream)
          next unless stream && stream.decoded
          icc = stream.encoded_data
          next unless icc.size >= 20
          return String.new(icc[16, 4]).rstrip
        end
        nil
      end

      # Device colour spaces set directly in page content streams
      # without the device-independent anchor PDF/A requires
      # (ISO 19005-2 § 6.2.4.3) : DeviceRGB needs an RGB OutputIntent
      # (or a DefaultRGB), DeviceCMYK a CMYK OutputIntent (or
      # DefaultCMYK), DeviceGray any OutputIntent (or a DefaultGray).
      getter device_colour_violations : Array(String) do
        issues = [] of String
        oi_space = output_intent_colour_space
        each_page do |page|
          data = page_content_bytes(page)
          next if data.empty?
          used = ContentStreamScanner.new(data).scan.device_colour_spaces
          next if used.empty?
          defaults = page_default_colour_spaces(page)
          if used.includes?("RGB") && oi_space != "RGB" && !defaults.includes?("DefaultRGB")
            issues << "DeviceRGB used without an RGB OutputIntent or DefaultRGB"
          end
          if used.includes?("CMYK") && oi_space != "CMYK" && !defaults.includes?("DefaultCMYK")
            issues << "DeviceCMYK used without a CMYK OutputIntent or DefaultCMYK"
          end
          if used.includes?("GRAY") && oi_space.nil? && !defaults.includes?("DefaultGray")
            issues << "DeviceGray used without any OutputIntent or DefaultGray"
          end
        end
        issues.uniq
      end

      # The Default* keys present in a page's /Resources /ColorSpace
      # dictionary (they redirect Device* usage to a device-independent
      # space, satisfying § 6.2.4.3).
      private def page_default_colour_spaces(page : PDF::Objects::Dictionary) : Set(String)
        result = Set(String).new
        resources = page["Resources"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
        return result unless resources
        spaces = resources["ColorSpace"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
        return result unless spaces
        {"DefaultRGB", "DefaultCMYK", "DefaultGray"}.each do |name|
          result << name if spaces.has_key?(name)
        end
        result
      end

      # Embedded-file specification violations (ISO 19005-2 § 6.8,
      # t2) : a file specification that carries an embedded file (/EF)
      # shall contain both /F and /UF. (t5 — the embedded file must
      # itself be PDF/A-1/2 — needs recursive validation and is out of
      # scope.)
      getter embedded_filespec_violations : Array(String) do
        issues = [] of String
        each_object do |obj|
          dict = obj.as?(PDF::Objects::Dictionary)
          next unless dict && dict.has_key?("EF")
          unless dict.has_key?("F") && dict.has_key?("UF")
            issues << "embedded-file specification missing /F or /UF"
          end
        end
        issues.uniq
      end

      # Optional-content (OCG) configuration violations (ISO 19005-2
      # § 6.9) : each configuration dictionary (the /D config and every
      # entry of /Configs) shall have a non-empty /Name (t1), the names
      # shall be unique (t2), and no configuration shall contain /AS
      # (t4). (t3 — /Order must list every OCG — needs an Order-tree
      # walk and is out of scope.)
      getter optional_content_violations : Array(String) do
        issues = [] of String
        ocprops = catalog["OCProperties"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
        return issues unless ocprops

        configs = [] of PDF::Objects::Dictionary
        if default = ocprops["D"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
          configs << default
        end
        if list = ocprops["Configs"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
          list.each do |entry|
            cfg = resolve(entry).as?(PDF::Objects::Dictionary)
            configs << cfg if cfg
          end
        end

        # Master list of every OCG in the file (§ 6.9 t3 needs it).
        all_ocgs = Set(UInt64).new
        if ocgs = ocprops["OCGs"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
          ocgs.each do |ref|
            dict = resolve(ref).as?(PDF::Objects::Dictionary)
            all_ocgs << dict.object_id if dict
          end
        end

        names = [] of String
        configs.each do |cfg|
          name = cfg["Name"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Str).try(&.value)
          if name.nil? || name.empty?
            issues << "optional-content configuration without a non-empty /Name"
          else
            names << name
          end
          issues << "optional-content configuration contains forbidden /AS" if cfg.has_key?("AS")

          # § 6.9 t3 : if a configuration carries /Order, that array must
          # reference every OCG in the file (groups are nested arrays with
          # an optional leading label string ; both are flattened away).
          if order = cfg["Order"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
            ordered = Set(UInt64).new
            collect_order_ocgs(order, ordered)
            missing = all_ocgs - ordered
            unless missing.empty?
              issues << "optional-content /Order does not reference all OCGs (#{missing.size} missing)"
            end
          end
        end
        issues << "duplicate optional-content configuration /Name" if names.size != names.uniq.size
        issues.uniq
      end

      # Recursively flattens an optional-content /Order array, recording
      # the object id of every OCG dictionary it references. Nested
      # arrays (group sub-trees) are descended ; leading label strings
      # and other scalars are ignored.
      private def collect_order_ocgs(node : PDF::Objects::Base, into : Set(UInt64))
        resolved = resolve(node)
        case resolved
        when PDF::Objects::Array
          resolved.each { |elem| collect_order_ocgs(elem, into) }
        when PDF::Objects::Dictionary
          into << resolved.object_id
        end
      end

      # Interactive-form action violations (ISO 19005-2 § 6.4.1) :
      # Widget annotations shall not carry /A or /AA (t1), form fields
      # shall not carry /AA (t2), and the AcroForm /NeedAppearances flag
      # shall be absent or false (t3).
      getter interactive_form_violations : Array(String) do
        issues = [] of String
        if acroform = catalog["AcroForm"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
          if acroform["NeedAppearances"]?.try(&.as?(PDF::Objects::Boolean)).try(&.value)
            issues << "AcroForm /NeedAppearances is true"
          end
        end
        each_annotation do |annot|
          next unless annot["Subtype"]?.try(&.as?(PDF::Objects::Name)).try(&.value) == "Widget"
          issues << "Widget annotation contains /A (action)" if annot.has_key?("A")
          issues << "Widget annotation contains /AA (additional actions)" if annot.has_key?("AA")
        end
        each_form_field do |field|
          issues << "form field contains /AA (additional actions)" if field.has_key?("AA")
        end
        issues.uniq
      end

      # Signature /ByteRange violations (ISO 19005-2 § 6.4.3, t1) : a
      # signature's /ByteRange must cover the entire file — start at
      # byte 0 and the second segment must end at end-of-file (the gap
      # between the two segments is the /Contents hole). Needs the raw
      # bytes ; empty when they are unavailable. (t2/t3 — the PKCS#7
      # signing certificate and SignerInfo count — need an ASN.1/DER
      # parser and live in the pdf-signature project.)
      getter signature_byterange_violations : Array(String) do
        issues = [] of String
        raw = @raw
        return issues unless raw
        size = raw.size
        each_object do |obj|
          dict = obj.as?(PDF::Objects::Dictionary)
          next unless dict && dict.has_key?("ByteRange") && dict.has_key?("Contents")
          range = dict["ByteRange"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
          next unless range && range.size == 4
          bounds = [] of Int64
          range.each do |elem|
            num = resolve(elem).as?(PDF::Objects::Number)
            next unless num
            bounds << num.to_i64
          end
          next unless bounds.size == 4
          unless bounds[0] == 0 && (bounds[2] + bounds[3]) == size
            issues << "signature /ByteRange does not cover the entire document"
          end
        end
        issues.uniq
      end

      # Dynamic / XFA form violations (ISO 19005-2 § 6.4.2) : the
      # AcroForm shall not contain /XFA (t1), and the catalog shall not
      # contain /NeedsRendering (t2).
      getter dynamic_form_violations : Array(String) do
        issues = [] of String
        issues << "catalog contains /NeedsRendering" if catalog.has_key?("NeedsRendering")
        if acroform = catalog["AcroForm"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
          issues << "AcroForm contains /XFA (XFA forms forbidden)" if acroform.has_key?("XFA")
        end
        issues.uniq
      end

      # ICC profile device classes / colour spaces ICCBased colour
      # spaces may use (ISO 19005-2 § 6.2.4.2, t1).
      ICC_INPUT_CLASSES = %w[prtr mntr scnr spac]
      ICC_INPUT_SPACES  = ["RGB ", "CMYK", "GRAY", "Lab "]

      # ICCBased colour-space profile violations (ISO 19005-2 § 6.2.4.2,
      # t1) : the ICC profile of an ICCBased colour space must be a
      # valid input/display/output/colour-space-conversion profile in
      # an RGB/CMYK/GRAY/Lab colour space. (t2 — overprint mode for
      # ICCBased CMYK — needs graphics-state tracking and is out of
      # scope.)
      getter iccbased_profile_violations : Array(String) do
        issues = [] of String
        each_object do |obj|
          arr = obj.as?(PDF::Objects::Array)
          next unless arr && arr.size >= 2
          next unless arr[0].as?(PDF::Objects::Name).try(&.value) == "ICCBased"
          stream = resolve(arr[1]).as?(PDF::Objects::Stream)
          next unless stream && stream.decoded
          icc = stream.encoded_data
          next unless icc.size >= 20
          cls = String.new(icc[12, 4])
          space = String.new(icc[16, 4])
          issues << "ICCBased profile device class #{cls.inspect}" unless ICC_INPUT_CLASSES.includes?(cls)
          issues << "ICCBased profile colour space #{space.inspect}" unless ICC_INPUT_SPACES.includes?(space)
        end
        issues.uniq
      end

      # Yields every interactive-form field dictionary, walking the
      # AcroForm /Fields tree (and /Kids) with cycle protection.
      private def each_form_field(&)
        acroform = catalog["AcroForm"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
        return unless acroform
        fields = acroform["Fields"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
        return unless fields
        visited = Set(UInt64).new
        stack = [] of PDF::Objects::Base
        fields.each { |field| stack << field }
        until stack.empty?
          dict = resolve(stack.pop).as?(PDF::Objects::Dictionary)
          next unless dict
          next unless visited.add?(dict.object_id)
          yield dict
          if kids = dict["Kids"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Array)
            kids.each { |kid| stack << kid }
          end
        end
      end

      # Implementation-limit violations (ISO 19005-2 § 6.1.13), the
      # dictionary/graph-checkable subset : integer range (t1), real
      # range (t2), real-near-zero (t5), string length (t3), name
      # length (t4), indirect-object count (t7), DeviceN colorant count
      # (t9) and page-boundary sizes (t11). The q/Q nesting depth (t8)
      # and CID range (t10) need a content-stream / CMap interpreter
      # and are out of scope here.
      getter implementation_limit_violations : Array(String) do
        issues = [] of String
        each_object do |obj|
          case obj
          when PDF::Objects::Number
            if obj.integer?
              value = obj.to_i64
              issues << "integer outside the ±2³¹ range (#{value})" if value > 2147483647_i64 || value < -2147483648_i64
            else
              real = obj.to_f64
              issues << "real outside the ±3.403e38 range" if real < -3.403e38 || real > 3.403e38
              issues << "real closer to zero than ±1.175e-38" unless real == 0.0 || real.abs >= 1.175e-38
            end
          when PDF::Objects::Str
            issues << "string longer than 32767 bytes" if obj.value.bytesize > 32767
          when PDF::Objects::Name
            issues << "name longer than 127 bytes" if obj.value.bytesize > 127
          when PDF::Objects::Array
            if obj.size >= 2 && obj[0].as?(PDF::Objects::Name).try(&.value) == "DeviceN"
              colorants = resolve(obj[1]).as?(PDF::Objects::Array)
              issues << "DeviceN colour space with more than 32 colorants" if colorants && colorants.size > 32
            end
          end
        end

        if count = trailer["Size"]?.try(&.as?(PDF::Objects::Number)).try(&.to_i64)
          issues << "more than 8388607 indirect objects" if count > 8388607
        end

        each_page do |page|
          {"MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox"}.each do |box_name|
            dims = box_dimensions(page[box_name]?)
            next unless dims
            width, height = dims
            unless width >= 3 && width <= 14400 && height >= 3 && height <= 14400
              issues << "#{box_name} outside the 3..14400 unit range"
            end
          end
        end

        if content_scan[:max_q] > 28
          issues << "q/Q graphics-state nesting deeper than 28 levels (#{content_scan[:max_q]})"
        end

        issues.uniq
      end

      # Operators in page content streams that ISO 32000-1 does not
      # define (§ 6.2.2 t1).
      getter undefined_content_operators : Array(String) do
        content_scan[:undefined]
      end

      # Content-stream scan aggregated over every page : the undefined
      # operators, the maximum q/Q nesting depth, and the invalid `ri`
      # rendering intents. Built once. Empty when there is no page
      # content.
      private getter content_scan : {undefined: Array(String), max_q: Int32, invalid_ri: Array(String)} do
        undefined = [] of String
        invalid_ri = [] of String
        max_q = 0
        each_page do |page|
          data = page_content_bytes(page)
          next if data.empty?
          scanner = ContentStreamScanner.new(data).scan
          undefined.concat(scanner.undefined_operators)
          invalid_ri.concat(scanner.invalid_rendering_intents)
          max_q = scanner.max_q_depth if scanner.max_q_depth > max_q
        end
        {undefined: undefined.uniq, max_q: max_q, invalid_ri: invalid_ri.uniq}
      end

      # Concatenated decoded bytes of a page's /Contents (a single
      # stream, or an array of streams joined by whitespace).
      private def page_content_bytes(page : PDF::Objects::Dictionary) : Bytes
        contents = page["Contents"]?
        return Bytes.empty unless contents
        resolved = resolve(contents)
        case resolved
        when PDF::Objects::Stream
          resolved.encoded_data
        when PDF::Objects::Array
          io = IO::Memory.new
          resolved.each do |entry|
            stream = resolve(entry).as?(PDF::Objects::Stream)
            next unless stream
            io.write(stream.encoded_data)
            io << '\n'
          end
          io.to_slice
        else
          Bytes.empty
        end
      end

      # Returns {width, height} of a page-boundary array, or nil if the
      # value is absent or not a 4-number array.
      private def box_dimensions(value : PDF::Objects::Base?) : Tuple(Float64, Float64)?
        return nil unless value
        arr = resolve(value).as?(PDF::Objects::Array)
        return nil unless arr && arr.size == 4
        coords = [] of Float64
        arr.each do |elem|
          num = resolve(elem).as?(PDF::Objects::Number)
          return nil unless num
          coords << num.to_f64
        end
        {(coords[2] - coords[0]).abs, (coords[3] - coords[1]).abs}
      end

      # Single-pass lexical scan of the raw bytes, shared by the
      # byte-level § 6.1 rules (hex strings, stream EOLs, indirect
      # spacing). Built once ; empty when raw bytes are unavailable.
      private getter byte_scan : ByteScanner do
        ByteScanner.new(@raw || Bytes.empty).scan
      end

      # Hexadecimal-string well-formedness (ISO 19005-2 § 6.1.6) :
      # even digit count and only hex digits.
      getter hex_string_violations : Array(String) do
        byte_scan.hex_string_violations
      end

      # Stream keyword EOL violations (ISO 19005-2 § 6.1.7.1, t2).
      getter stream_eol_violations : Array(String) do
        byte_scan.stream_eol_violations
      end

      # Indirect object/reference spacing violations (§ 6.1.9).
      getter indirect_spacing_violations : Array(String) do
        byte_scan.indirect_spacing_violations
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

      # Permissions dictionary violations (ISO 19005-2 § 6.1.12) : the
      # catalog /Perms dictionary may contain only the keys /UR3 and
      # /DocMDP (t1) ; and when /DocMDP is present, no signature
      # reference dictionary (/Type /SigRef) may carry /DigestLocation,
      # /DigestMethod or /DigestValue (t2). Absent /Perms — the common
      # case — yields no violation.
      getter permissions_dictionary_violations : Array(String) do
        issues = [] of String
        perms = catalog["Perms"]?.try { |ref| resolve(ref) }.as?(PDF::Objects::Dictionary)
        return issues unless perms

        perms.keys.each do |key|
          name = key.value
          unless name == "UR3" || name == "DocMDP"
            issues << "permissions dictionary contains forbidden key /#{name}"
          end
        end

        if perms.has_key?("DocMDP")
          each_object do |obj|
            dict = obj.as?(PDF::Objects::Dictionary)
            next unless dict
            next unless dict["Type"]?.try(&.as?(PDF::Objects::Name)).try(&.value) == "SigRef"
            {"DigestLocation", "DigestMethod", "DigestValue"}.each do |forbidden|
              if dict.has_key?(forbidden)
                issues << "signature reference dictionary contains forbidden /#{forbidden} (DocMDP present)"
              end
            end
          end
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

      # `true` if a page object exhibits transparency : either it
      # carries an explicit transparency group (/Group /S /Transparency)
      # or its /Resources reference an ExtGState that uses a soft mask, a
      # non-standard blend mode, or constant alpha below 1. Deliberately
      # conservative — it only reports transparency it can positively see.
      private def page_contains_transparency?(page : PDF::Objects::Dictionary) : Bool
        group = page["Group"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Dictionary)
        if group && group["S"]?.try(&.as?(PDF::Objects::Name)).try(&.value) == "Transparency"
          return true
        end

        resources = page["Resources"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Dictionary)
        return false unless resources
        egs = resources["ExtGState"]?.try { |obj| resolve(obj) }.as?(PDF::Objects::Dictionary)
        return false unless egs

        egs.values.each do |entry|
          gstate = resolve(entry).as?(PDF::Objects::Dictionary)
          next unless gstate
          return true if extgstate_uses_transparency?(gstate)
        end
        false
      end

      # `true` if an ExtGState dictionary enables transparency : a soft
      # mask other than /None, a blend mode other than Normal/Compatible,
      # or a fill/stroke constant alpha strictly below 1.
      private def extgstate_uses_transparency?(gstate : PDF::Objects::Dictionary) : Bool
        if smask = gstate["SMask"]?.try { |obj| resolve(obj) }
          name = smask.as?(PDF::Objects::Name).try(&.value)
          return true unless name == "None"
        end

        if bm = gstate["BM"]?.try { |obj| resolve(obj) }
          mode = bm.as?(PDF::Objects::Name).try(&.value)
          mode ||= bm.as?(PDF::Objects::Array).try(&.first?).try { |first| resolve(first) }
            .as?(PDF::Objects::Name).try(&.value)
          return true if mode && mode != "Normal" && mode != "Compatible"
        end

        {"ca", "CA"}.each do |key|
          val = gstate[key]?.try(&.as?(PDF::Objects::Number)).try(&.to_f64)
          return true if val && val < 1.0
        end
        false
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
