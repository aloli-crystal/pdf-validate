module PDF
  module Validate
    # Loads the rule set for a conformance profile.
    #
    # Rule sets ship as YAML files under `rules/` and are baked into
    # the binary at compile time (`read_file`), so the validator is
    # self-contained — no runtime file lookup that would break when
    # the shard is vendored under `lib/`.
    module RuleSet
      # Embedded YAML, one constant per profile.
      PDF_A_2B = {{ read_file("#{__DIR__}/../../rules/pdf-a-2b.yml") }}
      PDF_A_3B = {{ read_file("#{__DIR__}/../../rules/pdf-a-3b.yml") }}
      PDF_UA_1 = {{ read_file("#{__DIR__}/../../rules/pdf-ua-1.yml") }}

      # The known profile identifiers.
      PROFILES = {
        "pdf-a-2b" => PDF_A_2B,
        "pdf-a-3b" => PDF_A_3B,
        "pdf-ua-1" => PDF_UA_1,
      }

      # Returns the parsed rules for `profile`, or raises if the
      # profile is unknown.
      def self.for(profile : String) : Array(Rule)
        yaml = PROFILES[profile]? ||
               raise ArgumentError.new("Unknown profile #{profile.inspect}. Known: #{PROFILES.keys.join(", ")}")
        Array(Rule).from_yaml(yaml)
      end

      # The list of known profile identifiers.
      def self.profiles : Array(String)
        PROFILES.keys
      end
    end
  end
end
