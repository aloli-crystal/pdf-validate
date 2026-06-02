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
