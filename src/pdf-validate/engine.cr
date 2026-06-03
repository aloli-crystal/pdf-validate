module PDF
  module Validate
    # Evaluates a rule set against a parsed document and produces a
    # `Report`.
    class Engine
      getter rules : Array(Rule)
      getter profile : String

      def initialize(@profile : String)
        @rules = RuleSet.for(@profile)
      end

      # Runs every rule against `ctx` and returns the report.
      def run(ctx : Context) : Report
        results = @rules.map do |rule|
          outcome = Checks.evaluate(rule.check, rule.args, ctx)
          Result.new(rule, outcome.passed, outcome.detail)
        end
        Report.new(@profile, results)
      end
    end

    # --- Top-level entry points ---

    # Validates the PDF at `path` against `profile` and returns the
    # report.
    def self.file(path : String, profile : String = "pdf-a-2b") : Report
      bytes(File.open(path, "rb", &.getb_to_end), profile)
    end

    # Validates PDF `bytes` against `profile`. The raw bytes are handed
    # to the `Context` too, so the byte-level structure rules
    # (file header, trailing data after %%EOF) can run.
    def self.bytes(bytes : Bytes, profile : String = "pdf-a-2b") : Report
      reader = PDF::Reader.open(IO::Memory.new(bytes))
      Engine.new(profile).run(Context.new(reader, bytes))
    end

    # Validates an already-open reader. Byte-level rules are skipped
    # (the raw bytes are not available through a reader alone).
    def self.run(reader : PDF::Reader, profile : String = "pdf-a-2b") : Report
      Engine.new(profile).run(Context.new(reader))
    end
  end
end
