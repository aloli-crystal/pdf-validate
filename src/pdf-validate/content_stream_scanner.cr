module PDF
  module Validate
    # A single-pass tokeniser over a (decoded) content stream. It walks
    # the bytes, skips operands (numbers, strings, names, arrays,
    # dictionaries, inline-image data) and isolates the **operators**,
    # so the content-stream rules can run :
    #
    # * § 6.2.2  — every operator must be defined in ISO 32000-1.
    # * § 6.1.13 — the q/Q graphics-state stack is nested at most 28
    #              levels deep (t8).
    #
    # This is the validator's content-stream interpreter foundation ;
    # later milestones add graphics-state tracking (colour, rendering
    # intent…) on top of the same walk.
    class ContentStreamScanner
      # The content-stream operators ISO 32000-1 defines (Annex A).
      OPERATORS = Set{
        "b", "B", "b*", "B*", "BDC", "BMC", "BT", "BX", "BI", "ID", "EI",
        "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EMC", "ET",
        "EX", "f", "F", "f*", "G", "g", "gs", "h", "i", "j", "J", "K",
        "k", "l", "m", "M", "MP", "n", "q", "Q", "re", "RG", "rg", "ri",
        "s", "S", "SC", "SCN", "sc", "scn", "sh", "T*", "Tc", "Td", "TD",
        "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w",
        "W", "W*", "y", "'", "\"",
      }

      # Keyword operands that are NOT operators (PDF boolean/null
      # objects) — they must not be flagged as undefined operators.
      OPERAND_KEYWORDS = Set{"true", "false", "null"}

      getter undefined_operators = [] of String
      getter max_q_depth = 0

      def initialize(@data : Bytes)
      end

      # ameba:disable Metrics/CyclomaticComplexity
      def scan : self
        raw = @data
        size = raw.size
        depth = 0
        i = 0
        while i < size
          byte = raw[i]
          case
          when whitespace?(byte)
            i += 1
          when byte == 0x25 # '%' comment
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
              i = skip_hex_string(i)
            end
          when byte == 0x2F # '/' name
            i = skip_token(i + 1)
          when delimiter?(byte) # ) > ] [ { } etc. — single delimiter
            i += 1
          when number_start?(byte)
            i = skip_token(i)
          else
            token_end = skip_token(i)
            token = String.new(raw[i, token_end - i])
            i = handle_operator(token, token_end, pointerof(depth))
          end
        end
        self
      end

      # Processes a regular token as an operator. Returns the index to
      # resume scanning from (past inline-image data for `ID`).
      private def handle_operator(token : String, token_end : Int32, depth : Int32*) : Int32
        case token
        when "q"
          depth.value += 1
          @max_q_depth = depth.value if depth.value > @max_q_depth
        when "Q"
          depth.value -= 1 if depth.value > 0
        when "ID"
          return skip_inline_image_data(token_end)
        else
          unless OPERATORS.includes?(token) || OPERAND_KEYWORDS.includes?(token)
            @undefined_operators << token
          end
        end
        token_end
      end

      # --- byte helpers ---

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

      private def number_start?(byte : UInt8) : Bool
        (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2D || byte == 0x2E
      end

      # Reads a token from `from` up to the next whitespace or
      # delimiter ; returns the end index.
      private def skip_token(from : Int32) : Int32
        raw = @data
        size = raw.size
        j = from
        while j < size && !whitespace?(raw[j]) && !delimiter?(raw[j])
          j += 1
        end
        j == from ? from + 1 : j
      end

      private def skip_literal_string(i : Int32) : Int32
        raw = @data
        size = raw.size
        j = i + 1
        depth = 1
        while j < size && depth > 0
          byte = raw[j]
          if byte == 0x5C
            j += 2
          else
            depth += 1 if byte == 0x28
            depth -= 1 if byte == 0x29
            j += 1
          end
        end
        j
      end

      private def skip_hex_string(i : Int32) : Int32
        raw = @data
        size = raw.size
        j = i + 1
        while j < size && raw[j] != 0x3E
          j += 1
        end
        j < size ? j + 1 : j
      end

      # Skips inline-image binary data after the `ID` operator, up to a
      # delimited `EI` keyword. Returns the index past `EI`.
      private def skip_inline_image_data(from : Int32) : Int32
        raw = @data
        size = raw.size
        j = from
        while j + 1 < size
          if raw[j] == 0x45 && raw[j + 1] == 0x49 && # 'E' 'I'
             (j == 0 || whitespace?(raw[j - 1])) &&
             (j + 2 >= size || whitespace?(raw[j + 2]) || delimiter?(raw[j + 2]))
            return j + 2
          end
          j += 1
        end
        size
      end
    end
  end
end
