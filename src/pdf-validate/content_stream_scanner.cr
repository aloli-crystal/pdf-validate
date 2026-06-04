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

      # Device colour-setting operators → the device colour space they
      # select (ISO 32000-1 § 8.6.8). Used for the § 6.2.4.3 check.
      DEVICE_COLOUR_OPERATORS = {
        "rg" => "RGB", "RG" => "RGB",
        "k" => "CMYK", "K" => "CMYK",
        "g" => "GRAY", "G" => "GRAY",
      }

      # The four rendering intents ISO 32000-1 defines (Table 70), valid
      # as the operand of the `ri` operator (§ 6.2.6).
      VALID_RENDERING_INTENTS = Set{
        "AbsoluteColorimetric", "RelativeColorimetric",
        "Perceptual", "Saturation",
      }

      # Inline-image filters PDF/A forbids (ISO 19005-2 § 6.1.10) — the
      # LZW filter (abbreviated /LZW or full /LZWDecode) and /Crypt.
      FORBIDDEN_INLINE_FILTERS = Set{"LZW", "LZWDecode", "Crypt"}

      getter undefined_operators = [] of String
      getter max_q_depth = 0
      # Device colour spaces (RGB/CMYK/GRAY) set directly in the content
      # stream via rg/RG/k/K/g/G.
      getter device_colour_spaces = Set(String).new
      # Non-standard rendering intents passed to the `ri` operator.
      getter invalid_rendering_intents = [] of String
      # Forbidden filters named in an inline image's /F (or /Filter) key.
      getter inline_image_filters = [] of String
      # `true` once an operator that references a named resource appears
      # (Tf font, Do XObject, gs ExtGState, sh shading) — used for the
      # § 6.2.2 t2 Resources-dictionary check.
      getter? uses_named_resources = false
      # The most recent name token — the operand a following `ri`
      # consumes (`/Perceptual ri`).
      @last_name : String? = nil
      # Inline-image (BI…ID) parsing state for the § 6.1.10 filter check.
      @in_inline_image = false
      @inline_expect_filter = false
      @inline_in_filter_array = false

      # Text-showing state for the glyph checks (§ 6.2.11.4.1 / § 6.2.11.8).
      # Each run records the current font resource name, the shown bytes
      # and the text rendering mode in effect.
      getter glyph_runs = [] of NamedTuple(font: String, bytes: Bytes, mode: Int32)
      @current_font : String? = nil
      @text_render_mode = 0
      @last_number : Int32? = nil
      @pending_strings = [] of Bytes

      # Overprint/ICCBased-CMYK graphic-state tracking (§ 6.2.4.2 t2),
      # active only once `configure_overprint` injects the page's
      # resolved ExtGState and ICCBased-CMYK resource maps.
      getter? overprint_cmyk_violation = false
      @track_overprint = false
      @overprint_gs = {} of String => Tuple(Int32, Bool, Bool)
      @cmyk_iccbased = Set(String).new
      @gs_opm = 0
      @gs_op_stroke = false
      @gs_op_fill = false
      @gs_stroke_cmyk = false
      @gs_fill_cmyk = false
      @gs_stack = [] of Tuple(Int32, Bool, Bool, Bool, Bool)

      def initialize(@data : Bytes)
      end

      # Enables § 6.2.4.2 t2 tracking. `extgstates` maps each ExtGState
      # resource name to {OPM, overprint-stroke, overprint-fill} ;
      # `cmyk_iccbased` is the set of ICCBased-CMYK colour-space resource
      # names.
      def configure_overprint(extgstates : Hash(String, Tuple(Int32, Bool, Bool)), cmyk_iccbased : Set(String)) : self
        @track_overprint = true
        @overprint_gs = extgstates
        @cmyk_iccbased = cmyk_iccbased
        self
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
            stop, bytes = read_literal_string(i)
            @pending_strings << bytes
            i = stop
          when byte == 0x3C # '<'
            if i + 1 < size && raw[i + 1] == 0x3C
              i += 2 # '<<' dictionary open
            else
              stop, bytes = read_hex_string(i)
              @pending_strings << bytes
              i = stop
            end
          when byte == 0x2F # '/' name
            name_end = skip_token(i + 1)
            name = String.new(raw[i + 1, name_end - i - 1])
            @last_name = name
            note_inline_name(name) if @in_inline_image
            i = name_end
          when delimiter?(byte) # ) > ] [ { } etc. — single delimiter
            note_inline_delimiter(byte) if @in_inline_image
            i += 1
          when number_start?(byte)
            token_end = skip_token(i)
            @last_number = String.new(raw[i, token_end - i]).to_i?
            i = token_end
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
      #
      # ameba:disable Metrics/CyclomaticComplexity
      private def handle_operator(token : String, token_end : Int32, depth : Int32*) : Int32
        apply_overprint(token) if @track_overprint
        case token
        when "q"
          depth.value += 1
          @max_q_depth = depth.value if depth.value > @max_q_depth
        when "Q"
          depth.value -= 1 if depth.value > 0
        when "BI"
          @in_inline_image = true
          @inline_expect_filter = false
          @inline_in_filter_array = false
        when "ID"
          @in_inline_image = false
          @pending_strings.clear
          return skip_inline_image_data(token_end)
        when "ri"
          intent = @last_name
          @invalid_rendering_intents << intent if intent && !VALID_RENDERING_INTENTS.includes?(intent)
        when "Tf"
          @current_font = @last_name
          @uses_named_resources = true
          @pending_strings.clear
        when "Tr"
          @text_render_mode = @last_number || 0
          @pending_strings.clear
        when "Tj", "TJ", "'", "\""
          flush_text_run
        when "Do", "gs", "sh"
          @uses_named_resources = true
          @pending_strings.clear
        else
          if space = DEVICE_COLOUR_OPERATORS[token]?
            @device_colour_spaces << space
          end
          unless OPERATORS.includes?(token) || OPERAND_KEYWORDS.includes?(token)
            @undefined_operators << token
          end
          @pending_strings.clear
        end
        token_end
      end

      # Painting operators that paint a stroke / a fill (§ 6.2.4.2 t2).
      STROKE_PAINT_OPS = Set{"S", "s", "B", "B*", "b", "b*"}
      FILL_PAINT_OPS   = Set{"f", "F", "f*", "B", "B*", "b", "b*"}

      # Updates the overprint/colour-space graphic state on the relevant
      # operators and flags the § 6.2.4.2 t2 violation at paint time.
      private def apply_overprint(token : String)
        case token
        when "q"
          @gs_stack << {@gs_opm, @gs_op_stroke, @gs_op_fill, @gs_stroke_cmyk, @gs_fill_cmyk}
        when "Q"
          if state = @gs_stack.pop?
            @gs_opm, @gs_op_stroke, @gs_op_fill, @gs_stroke_cmyk, @gs_fill_cmyk = state
          end
        when "gs"
          if entry = @overprint_gs[@last_name]?
            @gs_opm, @gs_op_stroke, @gs_op_fill = entry
          end
        when "CS"
          @gs_stroke_cmyk = (name = @last_name) ? @cmyk_iccbased.includes?(name) : false
        when "cs"
          @gs_fill_cmyk = (name = @last_name) ? @cmyk_iccbased.includes?(name) : false
        else
          check_overprint(token)
        end
      end

      # Flags the violation when an ICCBased CMYK colour is painted with
      # overprint on and OPM = 1.
      private def check_overprint(token : String)
        return unless @gs_opm == 1
        if STROKE_PAINT_OPS.includes?(token) && @gs_op_stroke && @gs_stroke_cmyk
          @overprint_cmyk_violation = true
        end
        if FILL_PAINT_OPS.includes?(token) && @gs_op_fill && @gs_fill_cmyk
          @overprint_cmyk_violation = true
        end
      end

      # Records the pending shown strings as glyph runs under the current
      # font and text rendering mode (the text-showing operators Tj, TJ,
      # ', ").
      private def flush_text_run
        if font = @current_font
          @pending_strings.each do |bytes|
            @glyph_runs << {font: font, bytes: bytes, mode: @text_render_mode}
          end
        end
        @pending_strings.clear
      end

      # Handles a name token while inside an inline image dictionary
      # (between BI and ID) : records forbidden filter names and tracks
      # whether the next name(s) are the value of /F or /Filter.
      private def note_inline_name(name : String)
        if @inline_expect_filter
          record_inline_filter(name)
          @inline_expect_filter = false
          return
        end
        if @inline_in_filter_array
          record_inline_filter(name)
          return
        end
        @inline_expect_filter = true if name == "F" || name == "Filter"
      end

      # Tracks the `[ … ]` array delimiters of an inline image's /Filter
      # value so each filter name inside is examined.
      private def note_inline_delimiter(byte : UInt8)
        if byte == 0x5B && @inline_expect_filter # '['
          @inline_in_filter_array = true
          @inline_expect_filter = false
        elsif byte == 0x5D && @inline_in_filter_array # ']'
          @inline_in_filter_array = false
        end
      end

      private def record_inline_filter(name : String)
        @inline_image_filters << "/#{name}" if FORBIDDEN_INLINE_FILTERS.includes?(name)
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

      # Reads a literal string starting at '(' : returns the index past
      # the closing ')' and the decoded bytes (PDF escape sequences
      # resolved). These bytes are the character codes a following text
      # operator shows.
      private def read_literal_string(start : Int32) : Tuple(Int32, Bytes)
        raw = @data
        size = raw.size
        buf = IO::Memory.new
        j = start + 1
        depth = 1
        while j < size && depth > 0
          byte = raw[j]
          if byte == 0x5C # backslash escape
            j = read_string_escape(j, buf)
          else
            depth += 1 if byte == 0x28
            depth -= 1 if byte == 0x29
            buf.write_byte(byte) if depth > 0
            j += 1
          end
        end
        {j, buf.to_slice}
      end

      # Single-character backslash escapes → the byte they produce
      # (\n \r \t \b \f).
      SIMPLE_ESCAPES = {
        0x6E_u8 => 0x0A_u8, 0x72_u8 => 0x0D_u8, 0x74_u8 => 0x09_u8,
        0x62_u8 => 0x08_u8, 0x66_u8 => 0x0C_u8,
      }

      # Decodes one backslash escape at index `escape_at` (the
      # backslash), appending the resolved byte(s) to `buf` ; returns the
      # next index.
      private def read_string_escape(escape_at : Int32, buf : IO::Memory) : Int32
        raw = @data
        j = escape_at + 1
        return j if j >= raw.size
        byte = raw[j]
        if mapped = SIMPLE_ESCAPES[byte]?
          buf.write_byte(mapped)
          j + 1
        elsif byte == 0x0A # line continuation \<LF>
          j + 1
        elsif byte == 0x0D # line continuation \<CR> or \<CRLF>
          (j + 1 < raw.size && raw[j + 1] == 0x0A) ? j + 2 : j + 1
        elsif byte >= 0x30 && byte <= 0x37 # octal \ddd
          read_octal_escape(j, buf)
        else
          buf.write_byte(byte) # \( \) \\ or unknown → literal char
          j + 1
        end
      end

      # Reads a 1–3 digit octal escape starting at `start`, appends the
      # resulting byte to `buf`, and returns the next index.
      private def read_octal_escape(start : Int32, buf : IO::Memory) : Int32
        raw = @data
        size = raw.size
        value = 0
        count = 0
        j = start
        while count < 3 && j < size && raw[j] >= 0x30 && raw[j] <= 0x37
          value = value * 8 + (raw[j] - 0x30)
          j += 1
          count += 1
        end
        buf.write_byte((value & 0xFF).to_u8)
        j
      end

      # Reads a hex string starting at '<' : returns the index past the
      # closing '>' and the decoded bytes (whitespace ignored, an odd
      # final digit padded with 0).
      private def read_hex_string(start : Int32) : Tuple(Int32, Bytes)
        raw = @data
        size = raw.size
        buf = IO::Memory.new
        j = start + 1
        high : Int32? = nil
        while j < size && raw[j] != 0x3E
          value = hex_value(raw[j])
          if value
            if previous = high
              buf.write_byte(((previous << 4) | value).to_u8)
              high = nil
            else
              high = value
            end
          end
          j += 1
        end
        buf.write_byte(((high || 0) << 4).to_u8) if high
        {j < size ? j + 1 : j, buf.to_slice}
      end

      # The numeric value of a hexadecimal digit byte, or nil.
      private def hex_value(byte : UInt8) : Int32?
        case byte
        when 0x30..0x39 then (byte - 0x30).to_i
        when 0x41..0x46 then (byte - 0x41 + 10).to_i
        when 0x61..0x66 then (byte - 0x61 + 10).to_i
        else                 nil
        end
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
