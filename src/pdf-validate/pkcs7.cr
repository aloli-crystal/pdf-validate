module PDF
  module Validate
    # Minimal DER walker over the PKCS#7/CMS `SignedData` object found in
    # a signature dictionary's `/Contents` — just enough to answer the two
    # structural questions ISO 19005-2 § 6.4.3 asks (t2 / t3) :
    #
    # * **t2** — does the object embed the signer's X.509 certificate ?
    #   (a non-empty `certificates [0]` field)
    # * **t3** — does it carry exactly one `SignerInfo` ? (`signerInfos`
    #   SET cardinality)
    #
    # Deliberately self-contained (no openssl, no networking) so the
    # validator stays a pure byte-analysis tool, mirroring the other
    # in-house parsers (`Jpeg2000`, `ContentStreamScanner`). The canonical
    # full DER tree lives in `aloli-crystal/pdf-signature` ; here we only
    # need a read-only structural walk. Handles low-tag-number form and
    # definite lengths (all CMS structures use these) ; trailing reserved
    # zero-padding after the object is naturally ignored because we never
    # read past the outer SEQUENCE's declared length.
    module Pkcs7
      # The structural verdict over one signature's PKCS#7 `/Contents`.
      struct Analysis
        getter? certificate_present : Bool
        getter signer_info_count : Int32

        def initialize(@certificate_present : Bool, @signer_info_count : Int32)
        end

        def single_signer? : Bool
          @signer_info_count == 1
        end
      end

      # One DER TLV : its identifier octet, the offset/length of its value
      # and the offset just past the whole TLV.
      record TLV, tag : UInt8, value_start : Int32, value_len : Int32, next_pos : Int32

      # Structural analysis of a DER PKCS#7 `SignedData` ContentInfo, or
      # `nil` when `der` is not a parseable `SignedData` (so a non-PKCS#7
      # `/Contents` never yields a false positive).
      def self.analyze(der : ::Bytes) : Analysis?
        content_info = read_tlv(der, 0)
        return nil unless content_info && content_info.tag == 0x30_u8

        # ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT }
        explicit = children(der, content_info).find { |tlv| tlv.tag == 0xA0_u8 }
        return nil unless explicit
        signed_data = children(der, explicit).first?
        return nil unless signed_data && signed_data.tag == 0x30_u8

        # SignedData ::= SEQUENCE { version, digestAlgorithms SET,
        #   encapContentInfo, certificates [0] OPTIONAL, crls [1] OPTIONAL,
        #   signerInfos SET }
        members = children(der, signed_data)
        certs = members.find { |tlv| tlv.tag == 0xA0_u8 }
        cert_present = certs ? children(der, certs).any? { |child| child.tag == 0x30_u8 } : false
        signer_infos = members.reverse.find { |tlv| tlv.tag == 0x31_u8 }
        count = signer_infos ? children(der, signer_infos).size : 0

        Analysis.new(cert_present, count)
      end

      # The immediate children of a constructed TLV.
      def self.children(der : ::Bytes, parent : TLV) : ::Array(TLV)
        result = [] of TLV
        pos = parent.value_start
        finish = parent.value_start + parent.value_len
        while pos < finish
          tlv = read_tlv(der, pos)
          break unless tlv
          result << tlv
          pos = tlv.next_pos
        end
        result
      end

      # Reads one TLV at `pos` (definite length, low-tag-number only), or
      # `nil` on a malformed / truncated encoding.
      def self.read_tlv(der : ::Bytes, pos : Int32) : TLV?
        return nil if pos < 0 || pos >= der.size
        tag = der[pos]
        return nil if (tag & 0x1F_u8) == 0x1F_u8 # high-tag-number unsupported
        length, cursor = read_length(der, pos + 1) || return nil
        return nil if cursor + length > der.size
        TLV.new(tag, cursor, length, cursor + length)
      end

      # Reads a DER length at `pos`, returning `{length, next_pos}` or
      # `nil` on a malformed / indefinite / truncated length.
      def self.read_length(der : ::Bytes, pos : Int32) : Tuple(Int32, Int32)?
        return nil if pos >= der.size
        first = der[pos]
        cursor = pos + 1
        return {first.to_i, cursor} if first < 0x80_u8

        count = (first & 0x7F_u8).to_i
        return nil if count == 0 || count > 4
        length = 0
        count.times do
          return nil if cursor >= der.size
          length = (length << 8) | der[cursor].to_i
          cursor += 1
        end
        return nil if length < 0
        {length, cursor}
      end
    end
  end
end
