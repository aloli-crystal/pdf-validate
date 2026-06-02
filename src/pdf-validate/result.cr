module PDF
  module Validate
    # The outcome of evaluating one rule against a document.
    struct Result
      getter rule : Rule
      getter? passed : Bool
      getter detail : String?

      def initialize(@rule : Rule, @passed : Bool, @detail : String? = nil)
      end

      def failed? : Bool
        !@passed
      end

      # A failure that is fatal to conformance (rule severity error).
      def fatal? : Bool
        failed? && @rule.error?
      end
    end
  end
end
