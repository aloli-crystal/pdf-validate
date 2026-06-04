module PDF
  module Validate
    # A minimal reader for the structural metadata of a JPEG2000 image —
    # enough for the ISO 19005-2 § 6.2.8.3 checks (colour-channel count,
    # colour-space specifications, METH/APPROX/EnumCS of the 'colr'
    # boxes, and the per-component bit depth). It understands both the
    # JP2 box format and a raw codestream's SIZ marker. It never raises :
    # `parse` returns what it could read, or nil for clearly non-JPEG2000
    # data.
    class Jpeg2000
      record ColrSpec, meth : Int32, approx : Int32, enum_cs : Int32?

      getter num_components : Int32?
      getter bit_depth : Int32?
      getter? bpcc_present : Bool = false
      getter colr_specs = [] of ColrSpec

      # Parses JPEG2000 data (a /JPXDecode stream). Returns nil when the
      # data is neither a JP2 box stream nor a raw codestream.
      def self.parse(data : Bytes) : Jpeg2000?
        instance = new
        if jp2_signature?(data)
          instance.read_jp2(data)
        elsif data.size >= 4 && data[0] == 0xFF && data[1] == 0x4F
          instance.read_codestream(data)
        else
          return nil
        end
        instance
      end

      # The JP2 signature box : length 12, type 'jP  ', content 0x0D0A870A.
      private def self.jp2_signature?(data : Bytes) : Bool
        data.size >= 12 &&
          data[4] == 0x6A && data[5] == 0x50 && data[6] == 0x20 && data[7] == 0x20
      end

      # Walks the top-level JP2 boxes, descending into the 'jp2h' header
      # superbox to read 'ihdr', 'colr' and 'bpcc'.
      protected def read_jp2(data : Bytes)
        walk_boxes(data, 0, data.size) do |type, body_start, body_end|
          next unless type == "jp2h"
          walk_boxes(data, body_start, body_end) do |sub_type, sub_start, sub_end|
            case sub_type
            when "ihdr" then read_ihdr(data, sub_start, sub_end)
            when "colr" then read_colr(data, sub_start, sub_end)
            when "bpcc" then @bpcc_present = true
            end
          end
        end
      end

      # Iterates the boxes in [from, limit), yielding {type, body_start,
      # body_end}. Handles the XLBox (length 1) and to-end (length 0)
      # forms ; stops on any inconsistency.
      private def walk_boxes(data : Bytes, from : Int32, limit : Int32, &)
        pos = from
        while pos + 8 <= limit
          length = u32(data, pos).to_i64
          type = String.new(data[pos + 4, 4])
          if length == 1
            break if pos + 16 > limit
            length = u64(data, pos + 8).to_i64
            body_start = pos + 16
          elsif length == 0
            body_start = pos + 8
            length = (limit - pos).to_i64
          else
            body_start = pos + 8
          end
          box_end = pos + length
          break if box_end > limit || box_end <= pos
          yield type, body_start, box_end.to_i
          pos = box_end.to_i
        end
      end

      # Image Header box : HEIGHT(4) WIDTH(4) NC(2) BPC(1) …
      private def read_ihdr(data : Bytes, start : Int32, stop : Int32)
        return if start + 11 > stop
        @num_components = u16(data, start + 8).to_i
        bpc = data[start + 10]
        if bpc == 0xFF
          @bpcc_present = true # per-component depths differ → 'bpcc' box
        else
          @bit_depth = (bpc & 0x7F).to_i + 1
        end
      end

      # Colour Specification box : METH(1) PREC(1) APPROX(1) [EnumCS(4)].
      private def read_colr(data : Bytes, start : Int32, stop : Int32)
        return if start + 3 > stop
        meth = data[start].to_i
        approx = data[start + 2].to_i
        enum_cs = (meth == 1 && start + 7 <= stop) ? u32(data, start + 3).to_i : nil
        @colr_specs << ColrSpec.new(meth, approx, enum_cs)
      end

      # Raw codestream : the SIZ marker (0xFF51) right after SOC gives the
      # component count (Csiz) and per-component bit depths (Ssiz).
      protected def read_codestream(data : Bytes)
        return unless data.size > 4 && data[2] == 0xFF && data[3] == 0x51
        siz = 2
        return if siz + 40 > data.size
        csiz = u16(data, siz + 38).to_i
        @num_components = csiz
        depths = [] of Int32
        csiz.times do |i|
          offset = siz + 40 + i * 3
          break if offset >= data.size
          depths << (data[offset] & 0x7F).to_i + 1
        end
        @bit_depth = depths.first?
        @bpcc_present = true if depths.uniq.size > 1
      end

      private def u16(data : Bytes, offset : Int32) : UInt16
        (data[offset].to_u16 << 8) | data[offset + 1].to_u16
      end

      private def u32(data : Bytes, offset : Int32) : UInt32
        (data[offset].to_u32 << 24) | (data[offset + 1].to_u32 << 16) |
          (data[offset + 2].to_u32 << 8) | data[offset + 3].to_u32
      end

      private def u64(data : Bytes, offset : Int32) : UInt64
        high = u32(data, offset).to_u64
        (high << 32) | u32(data, offset + 4).to_u64
      end
    end
  end
end
