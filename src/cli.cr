require "./pdf-validate/cli"

# Standalone `pdf-validate` binary. All the logic lives in
# `PDF::Validate::CLI.run` (in `src/pdf-validate/cli.cr`) so it can also
# be called in-process from the unified `alolipdf` binary
# (aloli-crystal/pdf-tools).
exit PDF::Validate::CLI.run(ARGV)
