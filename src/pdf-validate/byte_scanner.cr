module PDF
  module Validate
    # A small single-pass lexical scanner over the raw PDF bytes, for
    # the byte-level § 6.1 rules the object graph cannot express :
    #
    # * § 6.1.6   — hexadecimal strings : even digit count + only hex
    #               digits.
    # * § 6.1.7.1 — the `stream` keyword is followed by CRLF or LF (not
    #               a lone CR) and `endstream` is preceded by an EOL
    #               (t2) ; the declared /Length matches the real data
    #               length (t1, checked separately by the Context which
    #               can resolve indirect /Length).
    # * § 6.1.9   — an indirect object/reference (`N G obj` / `N G R`)
    #               separates its parts by a single white-space char.
    #
    # The scanner skips the regions that must NOT be tokenised —
    # comments, literal strings and binary stream data — so the rules
    # only ever see genuine PDF syntax. `stream` data is skipped by
    # searching for the next `endstream`; a false match inside binary
    # data is astronomically unlikely for the 9-byte ASCII sequence.
    class ByteScanner
      getter hex_string_violations = [] of String
      getter stream_eol_violations = [] of String
      getter indirect_spacing_violations = [] of String
      getter name_utf8_violations = [] of String
      # Byte ranges of stream data, as {keyword_end, data_end} pairs :
      # data starts right after the EOL following `stream`, and ends at
      # the `endstream` keyword. Used by the Context for the § 6.1.7.1
      # t1 /Length check.
      getter stream_data_spans = [] of Tuple(Int32, Int32)

      def initialize(@raw : Bytes)
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def scan : self
        raw = @raw
        size = raw.size
        i = 0
        while i < size
          byte = raw[i]
          case
          when byte == 0x25 # '%' comment → skip to EOL
            i += 1
            while i < size && raw[i] != 0x0A && raw[i] != 0x0D
              i += 1
            end
          when byte == 0x28 # '(' literal string
            i = skip_literal_string(i)
          when byte == 0x3C # '<'
            if i + 1 < size && raw[i + 1] == 0x3C
              i += 2 # '<<' dictionary open
            else
              i = scan_hex_string(i)
            end
          when keyword_at?(i, "stream")
            i = skip_stream(i)
          when byte == 0x2F # '/' name object
            i = scan_name(i)
          when digit?(byte) && token_start?(i)
            i = try_indirect(i)
          else
            i += 1
          end
        end

        @hex_string_violations.uniq!
        @stream_eol_violations.uniq!
        @indirect_spacing_violations.uniq!
        @name_utf8_violations.uniq!
        self
      end

      # --- byte classification (ISO 32000-1 § 7.2) ---

      private def whitespace?(byte : UInt8) : Bool
        byte == 0x00 || byte == 0x09 || byte == 0x0A ||
          byte == 0x0C || byte == 0x0D || byte == 0x20
      end

      private def delimiter?(byte : UInt8) : Bool
        case byte
        when 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25
          true
        else
          false
        end
      end

      private def digit?(byte : UInt8) : Bool
        byte >= 0x30 && byte <= 0x39
      end

      private def hex_digit?(byte : UInt8) : Bool
        (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x46) ||
          (byte >= 0x61 && byte <= 0x66)
      end

      # A token starts at `i` if the previous byte is a boundary
      # (whitespace or delimiter), or `i` is the file start.
      private def token_start?(i : Int32) : Bool
        i == 0 || whitespace?(@raw[i - 1]) || delimiter?(@raw[i - 1])
      end

      # `true` if the keyword `kw` sits at `i` as a standalone token
      # (boundary before and after).
      private def keyword_at?(i : Int32, kw : String) : Bool
        return false unless token_start?(i)
        keyword_literal_at?(i, kw)
      end

      # `true` if `kw` matches at `i` and is followed by a boundary
      # (does not require a boundary before — the caller positions `i`).
      private def keyword_literal_at?(i : Int32, kw : String) : Bool
        raw = @raw
        bytes = kw.to_slice
        return false if i + bytes.size > raw.size
        idx = 0
        while idx < bytes.size
          return false if raw[i + idx] != bytes[idx]
          idx += 1
        end
        after = i + bytes.size
        after >= raw.size || whitespace?(raw[after]) || delimiter?(raw[after])
      end

      # Skips a literal string `(...)`, honouring backslash escapes and
      # nested parentheses. Returns the index past the closing ')'.
      private def skip_literal_string(i : Int32) : Int32
        raw = @raw
        size = raw.size
        j = i + 1
        depth = 1
        while j < size && depth > 0
          byte = raw[j]
          if byte == 0x5C # backslash escape → skip next byte
            j += 2
          else
            depth += 1 if byte == 0x28
            depth -= 1 if byte == 0x29
            j += 1
          end
        end
        j
      end

      # Scans a name object `/...` from the '/' at `i`, resolving `#XX`
      # escapes to their raw bytes, and records a § 6.1.8 t1 violation
      # when the resulting byte sequence is not valid UTF-8. (The object
      # parser re-encodes each `#XX` to a Unicode code point, so this
      # byte-level view is the only place the original bytes survive.)
      # Returns the index past the name.
      private def scan_name(i : Int32) : Int32
        raw = @raw
        size = raw.size
        decoded = [] of UInt8
        j = i + 1
        while j < size
          byte = raw[j]
          break if whitespace?(byte) || delimiter?(byte)
          if byte == 0x23 && j + 2 < size && hex_digit?(raw[j + 1]) && hex_digit?(raw[j + 2])
            decoded << ((hex_value(raw[j + 1]) << 4) | hex_value(raw[j + 2])).to_u8
            j += 3
          else
            decoded << byte
            j += 1
          end
        end
        unless valid_utf8?(decoded)
          @name_utf8_violations << "name object is not a valid UTF-8 byte sequence"
        end
        j
      end

      private def valid_utf8?(bytes : Array(UInt8)) : Bool
        return true if bytes.empty?
        String.new(Bytes.new(bytes.size) { |k| bytes[k] }).valid_encoding?
      end

      private def hex_value(byte : UInt8) : Int32
        if byte >= 0x30 && byte <= 0x39
          (byte - 0x30).to_i
        elsif byte >= 0x41 && byte <= 0x46
          (byte - 0x41 + 10).to_i
        else
          (byte - 0x61 + 10).to_i
        end
      end

      # Scans a hexadecimal string `<...>` from the opening '<' at `i`.
      # Records § 6.1.6 violations. Returns the index past '>'.
      private def scan_hex_string(i : Int32) : Int32
        raw = @raw
        size = raw.size
        j = i + 1
        count = 0
        non_hex = false
        while j < size && raw[j] != 0x3E # '>'
          byte = raw[j]
          unless whitespace?(byte)
            count += 1
            non_hex = true unless hex_digit?(byte)
          end
          j += 1
        end
        @hex_string_violations << "hex string contains a non-hexadecimal character" if non_hex
        @hex_string_violations << "hex string has an odd number of digits" if count.odd?
        j < size ? j + 1 : j
      end

      # Handles a `stream` keyword at `i` : records § 6.1.7.1 t2 EOL
      # violations and skips past the matching `endstream`. Returns the
      # index past `endstream` (or end of file if none found).
      private def skip_stream(i : Int32) : Int32
        raw = @raw
        size = raw.size
        after = i + 6 # past "stream"

        # t2 (part 1) : stream keyword must be followed by CRLF or LF.
        data_start = after
        if after < size && raw[after] == 0x0D
          if after + 1 < size && raw[after + 1] == 0x0A
            data_start = after + 2
          else
            @stream_eol_violations << "stream keyword followed by a lone CR (CRLF or LF required)"
            data_start = after + 1
          end
        elsif after < size && raw[after] == 0x0A
          data_start = after + 1
        else
          @stream_eol_violations << "stream keyword not followed by an EOL"
        end

        endpos = find_subsequence(data_start, "endstream")
        return size unless endpos

        # t2 (part 2) : endstream must be preceded by an EOL.
        if endpos > 0 && raw[endpos - 1] != 0x0A && raw[endpos - 1] != 0x0D
          @stream_eol_violations << "endstream keyword not preceded by an EOL"
        end

        @stream_data_spans << {data_start, endpos}
        endpos + 9 # past "endstream"
      end

      # Tries to read an indirect object/reference (`N G obj` or
      # `N G R`) starting at digit `i`. Records a § 6.1.9 violation if
      # either separator is not a single white-space character. Returns
      # the index to resume scanning from.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      private def try_indirect(i : Int32) : Int32
        raw = @raw
        size = raw.size

        j = i
        while j < size && digit?(raw[j]) # object number
          j += 1
        end

        ws1 = 0
        while j < size && whitespace?(raw[j])
          j += 1
          ws1 += 1
        end
        return i + 1 if ws1 == 0

        gen_start = j
        while j < size && digit?(raw[j]) # generation number
          j += 1
        end
        return i + 1 if j == gen_start

        ws2 = 0
        while j < size && whitespace?(raw[j])
          j += 1
          ws2 += 1
        end
        return i + 1 if ws2 == 0

        if keyword_literal_at?(j, "obj")
          record_spacing(ws1, ws2)
          j + 3
        elsif keyword_literal_at?(j, "R")
          record_spacing(ws1, ws2)
          j + 1
        else
          i + 1
        end
      end

      private def record_spacing(ws1 : Int32, ws2 : Int32) : Nil
        if ws1 != 1 || ws2 != 1
          @indirect_spacing_violations << "indirect object/reference separated by more than one white-space character"
        end
      end

      # Index of the next occurrence of `needle` at or after `from`, or
      # nil if none.
      private def find_subsequence(from : Int32, needle : String) : Int32?
        raw = @raw
        bytes = needle.to_slice
        last = raw.size - bytes.size
        i = from
        while i <= last
          matched = true
          idx = 0
          while idx < bytes.size
            if raw[i + idx] != bytes[idx]
              matched = false
              break
            end
            idx += 1
          end
          return i if matched
          i += 1
        end
        nil
      end
    end
  end
end
