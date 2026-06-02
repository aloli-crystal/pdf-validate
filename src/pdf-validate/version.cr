module PDF
  module Validate
    # Read at compile time from shard.yml (ALOLI convention — see
    # memo `feedback_shard_version_macro.md`).
    VERSION = {{
                (read_file("#{__DIR__}/../../shard.yml")
                  .lines
                  .find(&.starts_with?("version:")) || "version: 0.0.0")
                  .gsub(/^version:\s*/, "")
                  .chomp
              }}
  end
end
