require "json"

module PDF
  module Validate
    # The result of validating a document against a profile : the
    # per-rule results plus convenience predicates and renderers.
    class Report
      getter profile : String
      getter results : Array(Result)

      def initialize(@profile : String, @results : Array(Result))
      end

      # All failed rules.
      def failures : Array(Result)
        @results.select(&.failed?)
      end

      # Failed rules whose severity is fatal (error). A document is
      # conformant when it has no fatal failures.
      def fatal_failures : Array(Result)
        @results.select(&.fatal?)
      end

      # `true` if the document passes every error-severity rule.
      #
      # NOTE : this reflects the *implemented* rule set, which (in the
      # first palier) covers document-level requirements only. It is
      # not yet a full ISO 19005 certificate — see the shard README.
      def conformant? : Bool
        fatal_failures.empty?
      end

      def passed_count : Int32
        @results.count(&.passed?)
      end

      # Human-readable report.
      def to_s(io : IO) : Nil
        io << "PDF/Validate report — profile " << @profile << "\n"
        io << "=" * 56 << "\n"
        @results.each do |result|
          mark = result.passed? ? "PASS" : (result.rule.error? ? "FAIL" : "WARN")
          io << "[" << mark << "] " << result.rule.id << " — " << result.rule.title << "\n"
          io << "        " << result.rule.clause << "\n"
          if (d = result.detail) && result.failed?
            io << "        → " << d << "\n"
          end
        end
        io << "-" * 56 << "\n"
        io << passed_count << "/" << @results.size << " rules passed ; "
        io << (conformant? ? "CONFORMANT" : "#{fatal_failures.size} fatal violation(s)")
        io << "\n"
      end

      # Machine-readable report.
      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          builder.field "profile", @profile
          builder.field "conformant", conformant?
          builder.field "passed", passed_count
          builder.field "total", @results.size
          builder.field "results" do
            builder.array do
              @results.each do |result|
                builder.object do
                  builder.field "id", result.rule.id
                  builder.field "clause", result.rule.clause
                  builder.field "title", result.rule.title
                  builder.field "severity", result.rule.severity
                  builder.field "passed", result.passed?
                  builder.field "detail", result.detail
                end
              end
            end
          end
        end
      end
    end
  end
end
