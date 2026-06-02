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
        else
          raise "Unknown check #{check.inspect} (rule set references a primitive the engine does not implement)"
        end
      end
    end
  end
end
