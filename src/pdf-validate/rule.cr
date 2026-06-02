require "yaml"

module PDF
  module Validate
    # A single declarative conformance rule, loaded from a profile's
    # YAML rule set.
    #
    # ```yaml
    # - id: pdfa2-6.7.11-pdfaid-part
    #   clause: "ISO 19005-2 § 6.7.11"
    #   title: "PDF/A version identification present"
    #   severity: error
    #   check: xmp_contains
    #   args: ["<pdfaid:part>"]
    # ```
    #
    # `check` names a member of the engine's check vocabulary (see
    # `Checks`). `args` are the parameters that check consumes. Every
    # rule carries its ISO `clause` so reports are traceable.
    struct Rule
      include YAML::Serializable

      getter id : String
      getter clause : String
      getter title : String
      getter check : String

      @[YAML::Field(key: "severity")]
      getter severity : String = "error"

      getter args : Array(String) = [] of String

      # `true` if a failure of this rule is fatal to conformance
      # (severity "error"), as opposed to a "warning".
      def error? : Bool
        severity == "error"
      end
    end
  end
end
