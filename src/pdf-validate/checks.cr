module PDF
  module Validate
    # The check vocabulary : the finite set of primitive predicates a
    # rule's `check:` field can name. Each returns an `Outcome` —
    # whether the rule passed, plus an optional human detail used in
    # the report when it fails.
    #
    # Keeping the vocabulary small and explicit (rather than a free
    # query language) is deliberate : it keeps rule sets auditable
    # and the engine simple. New primitives are added here as new
    # ISO requirements need expressing.
    module Checks
      record Outcome, passed : Bool, detail : String?

      # Evaluates `check` (with `args`) against `ctx`. Unknown check
      # names raise — a malformed rule set must fail loudly, not pass
      # silently.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      def self.evaluate(check : String, args : Array(String), ctx : Context) : Outcome
        case check
        when "catalog_key_present"
          key = args[0]
          present = ctx.catalog.has_key?(key)
          Outcome.new(present, present ? nil : "catalog is missing /#{key}")
        when "catalog_key_absent"
          key = args[0]
          present = ctx.catalog.has_key?(key)
          Outcome.new(!present, present ? "catalog must not contain /#{key}" : nil)
        when "trailer_key_present"
          key = args[0]
          present = ctx.trailer.has_key?(key)
          Outcome.new(present, present ? nil : "trailer is missing /#{key}")
        when "trailer_key_absent"
          key = args[0]
          present = ctx.trailer.has_key?(key)
          Outcome.new(!present, present ? "trailer must not contain /#{key}" : nil)
        when "xmp_contains"
          needle = args[0]
          found = ctx.xmp.includes?(needle)
          Outcome.new(found, found ? nil : "XMP metadata does not contain #{needle.inspect}")
        when "xmp_matches"
          re = Regex.new(args[0])
          found = !(ctx.xmp =~ re).nil?
          Outcome.new(found, found ? nil : "XMP metadata does not match /#{args[0]}/")
        when "xmp_property_present"
          # An RDF property is present whether serialised in element
          # form (<ns:prop>…</ns:prop>) or attribute form
          # (ns:prop="…"). Tools differ : pdf writes element form,
          # Ghostscript/ocrmypdf write attribute form. Match both.
          prop = Regex.escape(args[0])
          re = Regex.new(%(#{prop}\\s*(?:>|=)))
          found = !(ctx.xmp =~ re).nil?
          Outcome.new(found, found ? nil : "XMP property #{args[0]} not present")
        when "xmp_property_equals"
          prop = Regex.escape(args[0])
          val = Regex.escape(args[1])
          # element : <ns:prop>val</ns:prop> ; attribute : ns:prop="val"
          re = Regex.new(%(#{prop}\\s*(?:>\\s*#{val}\\s*<|=\\s*["']\\s*#{val}\\s*["'])))
          found = !(ctx.xmp =~ re).nil?
          Outcome.new(found, found ? nil : "XMP property #{args[0]} is not #{args[1]}")
        when "all_fonts_embedded"
          non_embedded = ctx.non_embedded_fonts
          Outcome.new(
            non_embedded.empty?,
            non_embedded.empty? ? nil : "non-embedded font(s): #{non_embedded.join(", ")}"
          )
        when "no_javascript"
          js = ctx.has_javascript?
          Outcome.new(!js, js ? "document contains JavaScript action(s)" : nil)
        when "image_colorspaces_calibrated"
          bad = ctx.uncalibrated_image_colorspaces
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "uncalibrated device colour space without OutputIntent: #{bad.join(", ")}"
          )
        when "extgstate_no_transfer_functions"
          bad = ctx.extgstate_transfer_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "ExtGState transfer/halftone keys forbidden in PDF/A: #{bad.join(", ")}"
          )
        when "standard_blend_modes"
          bad = ctx.nonstandard_blend_modes
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "non-standard blend mode(s): #{bad.join(", ")}"
          )
        when "no_forbidden_xobjects"
          bad = ctx.forbidden_xobject_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "forbidden XObject construct(s): #{bad.join(", ")}"
          )
        when "image_dictionary_keys_valid"
          bad = ctx.image_dictionary_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "non-conformant image dictionary key(s): #{bad.join(", ")}"
          )
        when "rendering_intents_valid"
          bad = ctx.invalid_rendering_intents
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "non-standard rendering intent(s): #{bad.join(", ")}"
          )
        when "output_intent_profiles_valid"
          bad = ctx.output_intent_profile_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "OutputIntent/DestOutputProfile issue(s): #{bad.join(", ")}"
          )
        when "annotation_types_allowed"
          bad = ctx.forbidden_annotation_types
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "forbidden annotation subtype(s): #{bad.join(", ")}"
          )
        when "annotation_flags_valid"
          bad = ctx.annotation_flag_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "annotation /F flag issue(s): #{bad.join(", ")}"
          )
        when "annotation_appearances_valid"
          bad = ctx.annotation_appearance_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "annotation appearance issue(s): #{bad.join(", ")}"
          )
        when "stream_filters_allowed"
          bad = ctx.forbidden_stream_filters
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "forbidden stream filter(s): #{bad.join(", ")}"
          )
        when "no_external_stream_files"
          bad = ctx.external_stream_file_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "external file reference in stream: #{bad.join(", ")}"
          )
        when "no_alternate_presentations"
          bad = ctx.alternate_presentation_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "alternate-presentation construct(s): #{bad.join(", ")}"
          )
        when "file_header_valid"
          bad = ctx.file_header_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "file header issue(s): #{bad.join(", ")}"
          )
        when "no_data_after_eof"
          bad = ctx.data_after_eof_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : bad.join(", ")
          )
        when "hex_strings_valid"
          bad = ctx.hex_string_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "hexadecimal string issue(s): #{bad.join(", ")}"
          )
        when "stream_keyword_eol_valid"
          bad = ctx.stream_eol_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "stream keyword EOL issue(s): #{bad.join(", ")}"
          )
        when "indirect_object_spacing_valid"
          bad = ctx.indirect_spacing_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "indirect object spacing issue(s): #{bad.join(", ")}"
          )
        when "implementation_limits_respected"
          bad = ctx.implementation_limit_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "implementation limit(s) exceeded: #{bad.join(", ")}"
          )
        when "xmp_well_formed"
          bad = ctx.xmp_metadata_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "XMP metadata issue(s): #{bad.join(", ")}"
          )
        when "pdfaid_conformance_valid"
          bad = ctx.pdfaid_conformance_violations
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : bad.join(", ")
          )
        when "content_operators_defined"
          bad = ctx.undefined_content_operators
          Outcome.new(
            bad.empty?,
            bad.empty? ? nil : "undefined content-stream operator(s): #{bad.join(", ")}"
          )
        else
          raise "Unknown check #{check.inspect} (rule set references a primitive the engine does not implement)"
        end
      end
    end
  end
end
