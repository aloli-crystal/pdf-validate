require "./pdf-validate"
require "json"

# CLI for the PDF conformance validator.
#
#   pdf-validate <file.pdf> [-p <profile>] [-j] [-q]
#   pdf-validate help [<topic>]
#   pdf-validate --version
#
# Exit code : 0 if conformant, 1 if violations, 2 on usage/IO error.
module PDF::Validate::CLI
  USAGE = <<-USAGE
  pdf-validate — declarative PDF conformance validator (ALOLI ISO PDF suite)

  Usage:
    pdf-validate <file.pdf> [options]
    pdf-validate help [<topic>]
    pdf-validate --version | -v

  Options:
    -p, --profile <id>   Conformance profile (default: pdf-a-2b)
    -j, --json           Emit the report as JSON instead of text
    -q, --quiet          Print nothing; rely on the exit code
    -h, --help           Show this help

  Profiles:
    #{PDF::Validate::RuleSet.profiles.join(", ")}

  Exit codes:
    0  conformant       1  violations found       2  usage / IO error
  USAGE

  # ameba:disable Metrics/CyclomaticComplexity
  def self.run(argv : Array(String)) : Int32
    # `help` positional subcommand (ALOLI CLI convention).
    if argv.first? == "help"
      puts USAGE
      return 0
    end

    profile = "pdf-a-2b"
    json = false
    quiet = false
    file : String? = nil

    i = 0
    while i < argv.size
      arg = argv[i]
      case arg
      when "-h", "--help"
        puts USAGE
        return 0
      when "-v", "--version"
        puts PDF::Validate::VERSION
        return 0
      when "-j", "--json"
        json = true
      when "-q", "--quiet"
        quiet = true
      when "-p", "--profile"
        i += 1
        profile = argv[i]? || (STDERR.puts("error: -p/--profile needs an argument"); return 2)
      else
        if arg.starts_with?("-")
          STDERR.puts "error: unknown option #{arg}"
          STDERR.puts "Try 'pdf-validate help'."
          return 2
        end
        file = arg
      end
      i += 1
    end

    unless path = file
      STDERR.puts "error: no input file. Try 'pdf-validate help'."
      return 2
    end
    unless File.exists?(path)
      STDERR.puts "error: file not found: #{path}"
      return 2
    end
    unless PDF::Validate::RuleSet.profiles.includes?(profile)
      STDERR.puts "error: unknown profile #{profile.inspect}. Known: #{PDF::Validate::RuleSet.profiles.join(", ")}"
      return 2
    end

    report = PDF::Validate.file(path, profile)

    unless quiet
      if json
        puts report.to_json
      else
        puts report
      end
    end

    report.conformant? ? 0 : 1
  rescue ex
    STDERR.puts "error: #{ex.message}"
    2
  end
end

exit PDF::Validate::CLI.run(ARGV)
