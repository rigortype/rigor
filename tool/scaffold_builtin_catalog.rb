#!/usr/bin/env ruby
# frozen_string_literal: true

# Scaffolds the mechanical 70 % of a built-in catalog import:
# - the `TOPICS` entry in `tool/extract_builtin_catalog.rb`
# - the matching `BASE_CLASS_VARS` row when a new `rb_c*` /
#   `rb_m*` global needs to be registered
# - the loader file under `lib/rigor/inference/builtins/`
# - the `CATALOG_BY_CLASS` row plus the `require_relative` line
#   in `lib/rigor/inference/method_dispatcher/constant_folding.rb`
# - a fixture stub under `spec/integration/fixtures/`
# - the matching integration `describe` block in
#   `spec/integration/type_construction_spec.rb`
#
# Manual follow-ups the script intentionally leaves to the
# operator (the per-class judgement calls):
# - blocklist curation in the loader file (read the generated
#   YAML and add false-positive `:leaf` entries with one-line
#   comments naming the indirect mutator helper);
# - fixture body — replace the placeholder `assert_type` lines
#   with the receiver-specific projections the catalog unlocks;
# - `[Unreleased]` bullet in `CHANGELOG.md`.
#
# Usage:
#   ruby tool/scaffold_builtin_catalog.rb TOPIC CLASS_NAME [OPTIONS]
#
#   TOPIC          Topic key in TOPICS (lowercase, e.g. "time").
#   CLASS_NAME     Ruby class identifier (e.g. "Time").
#
# Options:
#   --c-path PATH       Source `.c` file (default: references/ruby/<topic>.c)
#   --rb-prelude PATH   Prelude `.rb` file (default: references/ruby/<topic>.rb if present, else nil)
#   --rbs PATH          RBS sig file (default: references/rbs/core/<topic>.rbs)
#   --init-fn NAME      Init function name (default: "Init_<ClassName>")
#   --rb-global SYM     `rb_c*` / `rb_m*` global to register in BASE_CLASS_VARS
#   --module            CLASS_NAME is a module (Comparable, Enumerable, …)
#                       — skip the `CATALOG_BY_CLASS` row (modules are not
#                       receiver classes the dispatcher routes through)
#                       and emit a different placeholder fixture banner.
#   --extract           Run `make extract-builtin-catalogs` after scaffolding
#   --dry-run           Print planned actions without writing
#   -h / --help         Show this banner

require "optparse"
require "fileutils"

ROOT = File.expand_path("..", __dir__)

# ---------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------

options = {
  c_path: nil,
  rb_prelude: nil,
  rbs_path: nil,
  init_fn: nil,
  rb_global: nil,
  module_kind: false,
  extract: false,
  dry_run: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tool/scaffold_builtin_catalog.rb TOPIC CLASS_NAME [OPTIONS]"
  opts.on("--c-path PATH") { |v| options[:c_path] = v }
  opts.on("--rb-prelude PATH") { |v| options[:rb_prelude] = v }
  opts.on("--rbs PATH") { |v| options[:rbs_path] = v }
  opts.on("--init-fn NAME") { |v| options[:init_fn] = v }
  opts.on("--rb-global SYM") { |v| options[:rb_global] = v }
  opts.on("--module") { options[:module_kind] = true }
  opts.on("--extract") { options[:extract] = true }
  opts.on("--dry-run") { options[:dry_run] = true }
  opts.on("-h", "--help") do
    puts opts
    exit 0
  end
end

parser.parse!(ARGV)

if ARGV.size != 2
  warn parser.help
  exit 1
end

topic = ARGV[0]
class_name = ARGV[1]

unless topic.match?(/\A[a-z][a-z0-9_]*\z/)
  warn "TOPIC must be a lowercase identifier (got #{topic.inspect})"
  exit 1
end

unless class_name.match?(/\A[A-Z][A-Za-z0-9_]*\z/)
  warn "CLASS_NAME must be a Capitalised identifier (got #{class_name.inspect})"
  exit 1
end

c_path = options[:c_path] || "references/ruby/#{topic}.c"
prelude = options[:rb_prelude]
prelude = "references/ruby/#{topic}.rb" if prelude.nil? && File.file?(File.join(ROOT, "references/ruby/#{topic}.rb"))
rbs_path = options[:rbs_path] || "references/rbs/core/#{topic}.rbs"
init_fn = options[:init_fn] || "Init_#{class_name}"
rb_global = options[:rb_global]

unless File.file?(File.join(ROOT, c_path))
  warn "C path does not exist: #{c_path}"
  exit 1
end

# ---------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------

EXTRACTOR_PATH = "tool/extract_builtin_catalog.rb"
LOADER_DIR = "lib/rigor/inference/builtins"
LOADER_PATH = "#{LOADER_DIR}/#{topic}_catalog.rb"
DISPATCHER_PATH = "lib/rigor/inference/method_dispatcher/constant_folding.rb"
FIXTURE_DIR = "spec/integration/fixtures"
FIXTURE_PATH = "#{FIXTURE_DIR}/#{topic}_catalog.rb"
INTEGRATION_SPEC_PATH = "spec/integration/type_construction_spec.rb"

CATALOG_CONST = "#{class_name.upcase}_CATALOG"

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def report(msg, dry_run:)
  prefix = dry_run ? "[scaffold dry-run]" : "[scaffold]"
  puts "#{prefix} #{msg}"
end

def write_file!(rel, content, dry_run:)
  full = File.join(ROOT, rel)
  if File.exist?(full)
    warn "[scaffold] refusing to overwrite existing #{rel}; remove it first if you intend to re-scaffold."
    exit 1
  end
  report("write   #{rel}", dry_run: dry_run)
  return if dry_run

  FileUtils.mkdir_p(File.dirname(full))
  File.write(full, content)
end

def edit_file!(rel, dry_run:)
  full = File.join(ROOT, rel)
  body = File.read(full, encoding: "UTF-8")
  new_body = yield(body)
  if new_body == body
    report("no-op   #{rel} (already contains the scaffold; remove the existing entry first to re-scaffold)",
           dry_run: dry_run)
    return
  end

  report("update  #{rel}", dry_run: dry_run)
  return if dry_run

  File.write(full, new_body)
end

# ---------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------

# Matches the existing two-space indentation inside the TOPICS
# hash literal. `<<~` strips the heredoc's common leading
# whitespace, so we re-add a uniform two-space prefix afterwards
# (the body's natural indent is already correct relative to the
# entry's own brace).
topics_block = <<~ENTRY.chomp.gsub(/^/, "  ")
  "#{topic}" => {
    init_function: "#{init_fn}",
    ruby_c_path: "#{c_path}",
    ruby_prelude_path: #{prelude ? "\"#{prelude}\"" : "nil"},
    rbs_paths: {
      "#{class_name}" => "#{rbs_path}"
    },
    c_index_paths: %w[#{c_path}],
    output_path: "data/builtins/ruby_core/#{topic}.yml"
  }
ENTRY

base_class_vars_row = rb_global ? %(  "#{rb_global}" => "#{class_name}") : nil

loader_header_lines =
  if options[:module_kind]
    [
      "      # `#{class_name}` module catalog. Singleton — load once.",
      "      #",
      "      # `#{class_name}` is a Ruby module, not a class, so the",
      "      # catalog is NOT routed through",
      "      # `MethodDispatcher::ConstantFolding::CATALOG_BY_CLASS`",
      "      # (which dispatches on the receiver's concrete class).",
      "      # The data is consumed by future include-aware lookup —",
      "      # see `docs/CURRENT_WORK.md` for the planned slice."
    ]
  else
    [
      "      # `#{class_name}` catalog. Singleton — load once, consult during",
      "      # dispatch.",
      "      #",
      "      # TODO(blocklist curation): read",
      "      # `data/builtins/ruby_core/#{topic}.yml` and add per-method",
      "      # blocklist entries for any `:leaf` classifications that are",
      "      # actually mutators or otherwise unsafe to fold. Each entry",
      "      # SHOULD carry a one-line comment naming the indirect mutator",
      "      # helper that triggered the false positive (see",
      "      # `string_catalog.rb`, `array_catalog.rb`, `time_catalog.rb`",
      "      # for the canonical shape)."
    ]
  end

blocklist_inner_lines =
  if options[:module_kind]
    []
  else
    [
      "          # initialize_copy is blocklisted by convention so a",
      "          # hypothetical future `Constant<#{class_name}>` carrier",
      "          # cannot fold an aliasing copy through the catalog.",
      "          :initialize_copy"
    ]
  end

blocklist_block_lines =
  if blocklist_inner_lines.empty?
    ["          \"#{class_name}\" => Set[]"]
  else
    [
      "          \"#{class_name}\" => Set[",
      *blocklist_inner_lines,
      "          ]"
    ]
  end

loader_template = ([
  "# frozen_string_literal: true",
  "",
  "require_relative \"method_catalog\"",
  "",
  "module Rigor",
  "  module Inference",
  "    module Builtins"
] + loader_header_lines + [
  "      #{class_name.upcase}_CATALOG = MethodCatalog.new(",
  "        path: File.expand_path(",
  "          \"../../../../data/builtins/ruby_core/#{topic}.yml\",",
  "          __dir__",
  "        ),",
  "        mutating_selectors: {",
  *blocklist_block_lines,
  "        }",
  "      )",
  "    end",
  "  end",
  "end",
  ""
]).join("\n")

fixture_template = <<~RUBY
  require "rigor/testing"
  include Rigor::Testing

  # Catalog-driven folding for `#{class_name}` — generated by
  # `tool/scaffold_builtin_catalog.rb`. Replace the placeholder
  # assertions below with class-specific projections that the
  # newly imported catalog unlocks.

  # TODO(scaffold): drive at least one method dispatch through
  # the catalog (e.g. an instance reader, a singleton constructor,
  # or a blocklisted mutator) and `assert_type` against the
  # resulting type's `describe(:short)` rendering.
  #
  # Example shape (delete after replacing):
  #
  #   t = #{class_name}.new
  #   assert_type("#{class_name}", t)
  #   assert_type("Integer", t.some_reader)
  RUBY

integration_describe = <<~RUBY
    describe "fixtures/#{topic}_catalog.rb — #{class_name} catalog-driven folding" do
      let(:harness) { harness_for("#{topic}_catalog") }

      it "self-asserts the new #{class_name} catalog coverage" do
        mismatches = harness.errors.select { |d| d.message.start_with?("assert_type ") }
        expect(mismatches).to be_empty
      end
    end
RUBY

# ---------------------------------------------------------------------
# Edits
# ---------------------------------------------------------------------

dry_run = options[:dry_run]

# 1. TOPICS entry + (optional) BASE_CLASS_VARS row
edit_file!(EXTRACTOR_PATH, dry_run: dry_run) do |body|
  next body if body.include?("\"#{topic}\" =>")

  new_body = body
  if base_class_vars_row && !new_body.include?("\"#{rb_global}\" =>")
    # Insert before the `}.freeze` that closes BASE_CLASS_VARS.
    new_body = new_body.sub(/(BASE_CLASS_VARS = \{\n.*?)(\n\}\.freeze)/m) do
      "#{::Regexp.last_match(1)},\n#{base_class_vars_row}#{::Regexp.last_match(2)}"
    end
  end

  # Insert before the `}.freeze` that closes TOPICS. The TOPICS hash's
  # last entry has no trailing comma, so we add one to its closing
  # brace before appending the new block.
  new_body.sub(/(TOPICS = \{\n.*?  \})(\n\}\.freeze)/m) do
    "#{::Regexp.last_match(1)},\n#{topics_block}#{::Regexp.last_match(2)}"
  end
end

# 2. Loader file
write_file!(LOADER_PATH, loader_template, dry_run: dry_run)

# 3. require_relative + (when --module is NOT set) CATALOG_BY_CLASS row
edit_file!(DISPATCHER_PATH, dry_run: dry_run) do |body|
  next body if body.include?("Builtins::#{CATALOG_CONST}")

  # Add the require_relative line next to the others. Both class
  # and module catalogs need this so the constant exists at boot.
  body = body.sub(
    /(require_relative "\.\.\/builtins\/[a-z_]+_catalog"\n)(?!require_relative "\.\.\/builtins\/[a-z_])/,
    "\\1require_relative \"../builtins/#{topic}_catalog\"\n"
  )

  # Module catalogs (`--module`) are not receiver classes, so the
  # constant-fold dispatcher does not route through them today.
  # The require_relative above keeps the singleton reachable for
  # future include-aware lookup; the CATALOG_BY_CLASS row stays
  # absent.
  next body if options[:module_kind]

  # Append the CATALOG_BY_CLASS row before the closing bracket.
  # The exact column padding inside each row is hand-aligned;
  # the script ships a sensibly-spaced default and the operator
  # can re-align later if desired.
  catalog_row = %(          [#{class_name}, [Builtins::#{CATALOG_CONST}, "#{class_name}"]])
  body.sub(/(CATALOG_BY_CLASS = \[\n.*?)\n        \]\.freeze/m) do
    "#{::Regexp.last_match(1)},\n#{catalog_row}\n        ].freeze"
  end
end

# 4. Fixture file (skipped under --module — module catalogs are
#    not currently dispatched through, so a fixture would have
#    no observable behaviour to assert against).
unless options[:module_kind]
  write_file!(FIXTURE_PATH, fixture_template, dry_run: dry_run)
end

# 5. Integration describe block — append before the last `end` of the
#    outer RSpec.describe. Skipped under --module for the same reason.
unless options[:module_kind]
  edit_file!(INTEGRATION_SPEC_PATH, dry_run: dry_run) do |body|
    next body if body.include?("fixtures/#{topic}_catalog.rb")

    body.sub(/(\n  end\nend\n)\z/) { "\n#{integration_describe}#{::Regexp.last_match(1)}" }
  end
end

# 6. Optionally run the extractor for the new topic.
if options[:extract] && !dry_run
  Dir.chdir(ROOT) do
    cmd = "nix --extra-experimental-features 'nix-command flakes' develop --command " \
          "bundle exec ruby tool/extract_builtin_catalog.rb #{topic}"
    report("run     #{cmd}", dry_run: false)
    system(cmd) || abort("[scaffold] extractor run failed")
  end
end

# ---------------------------------------------------------------------
# Final checklist
# ---------------------------------------------------------------------

if options[:module_kind]
  puts <<~CHECKLIST

    Done (module mode).

      1. #{options[:extract] ? "Inspect data/builtins/ruby_core/#{topic}.yml — verify" : "Run `make extract-builtin-catalogs` to generate data/builtins/ruby_core/#{topic}.yml, then verify"}
         the method classifications. Module catalogs do not feed
         `MethodDispatcher::ConstantFolding::CATALOG_BY_CLASS`
         today; the data is loaded as a singleton via
         `require_relative` so a future include-aware lookup can
         consult it.
      2. Add a [Unreleased] bullet to CHANGELOG.md describing
         the catalog import (e.g. "X imported built-in module
         catalog landed; YAML is consumed by the future
         include-aware dispatcher").
      3. Run `make verify` and commit.
  CHECKLIST
else
  puts <<~CHECKLIST

    Done.#{" Now run the manual follow-ups:" unless options[:extract]}

      1. #{options[:extract] ? "Inspect data/builtins/ruby_core/#{topic}.yml — read the classifications and curate" : "Run `make extract-builtin-catalogs` to generate data/builtins/ruby_core/#{topic}.yml, then curate"}
         the blocklist in #{LOADER_PATH} (mark
         any false-positive `:leaf` classifications with a one-line
         comment naming the indirect mutator helper).
      2. Replace the placeholder `assert_type` lines in
         #{FIXTURE_PATH} with receiver-specific
         projections that exercise the new catalog.
      3. Add a [Unreleased] bullet to CHANGELOG.md describing the
         user-visible additions (mirror the Hash / Range / Set / Time
         bullet shape).
      4. Run `make verify` and commit.
  CHECKLIST
end
