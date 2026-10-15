# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

%w[rigor-ffi rigor-dry-schema rigor-dry-validation].each do |gem_name|
  lib = File.expand_path("../../plugins/#{gem_name}/lib", __dir__)
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
  require gem_name
end

# Issue #1803 — the run-result caches (the `--incremental` slot and the plain `rigor check` entry) answer a
# run whose analysed files are unchanged without loading a plugin, so a project file a plugin reads reaches
# them only as a row of the plugin's IoBoundary. Each plugin here read some of its input with plain `Dir.glob`
# or `Prism.parse_file`, so changing that input alone was served the previous diagnostics. The input changed
# below is a file `exclude:` keeps out of analysis: an analysed file would join the path set, which no
# run-result cache is keyed by, and would hide the gap.
RSpec.describe "run-result caches over a plugin's own project inputs (#1803)" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def check(*flags)
    out = StringIO.new
    err = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: err).run
    [out.string, err.string]
  end

  def rules(json)
    JSON.parse(json).fetch("diagnostics").map do |diagnostic|
      "#{File.basename(diagnostic.fetch('path'))} #{diagnostic.fetch('rule')}"
    end
  end

  def write_project(plugins_yaml)
    File.write(".rigor.yml", "paths:\n  - lib\nexclude:\n  - \"**/gen/**\"\nplugins:\n#{plugins_yaml}")
    FileUtils.mkdir_p("lib/gen")
  end

  # Primes both caches: each mode's second run is the one served from its run-result entry.
  def prime
    2.times { check("--incremental") }
    2.times { check }
  end

  def expect_both_caches_to_match_cold(expected_rule)
    cold = rules(check("--no-cache").first)
    expect(cold).to include(expected_rule)
    expect(rules(check("--incremental").first)).to eq(cold)
    expect(rules(check.first)).to eq(cold)
  end

  describe "rigor-ffi's :ffi_catalog" do
    before do
      Rigor::Plugin.register(Rigor::Plugin::FFI)
      write_project("  - gem: rigor-ffi\n    id: ffi\n")
      File.write("lib/a.rb", "module L\n  extend FFI::Library\nend\n")
      File.write("lib/b.rb", "L.foo.bogus_meth\n")
    end

    # The producer declares no `watch:`, so its own entry carried no row before #1803 either: it was served
    # past an edit to an analysed file too, in a run the edit had already sent past both run-result caches.
    it "rebuilds the catalog once an analysed file attaches a function" do
      prime
      File.write("lib/a.rb", "module L\n  extend FFI::Library\n  attach_function :foo, [], :int\nend\n")

      expect(rules(check.first)).to eq(rules(check("--no-cache").first))
      expect(rules(check("--no-cache").first)).to include("b.rb call.undefined-method")
    end

    it "drops both run-result caches once an excluded file attaches a function" do
      prime
      File.write("lib/gen/a.rb", "module L\n  attach_function :foo, [], :int\nend\n")

      expect_both_caches_to_match_cold("b.rb call.undefined-method")
    end

    it "keeps serving the --incremental slot while the catalog's inputs are unchanged" do
      prime
      allow(Rigor::Analysis::IncrementalSession).to receive(:new).and_call_original

      expect(check("--incremental")[1]).to include("--incremental warm")
      expect(Rigor::Analysis::IncrementalSession).not_to have_received(:new)
    end

    # A top-level entry that changes kind under the same name: the walk's glob row sees the `.rb` files the new
    # directory holds. `paths:` is `lib`, so only the catalog sees those files.
    context "with a top-level entry that becomes a directory" do
      def make_directory(name)
        FileUtils.rm_rf(name)
        FileUtils.mkdir_p(name)
        File.write("#{name}/a.rb", "module L\n  attach_function :foo, [], :int\nend\n")
      end

      it "drops both run-result caches when a file becomes a directory" do
        File.write("gen", "not ruby\n")
        prime
        make_directory("gen")

        expect_both_caches_to_match_cold("b.rb call.undefined-method")
      end

      it "drops both run-result caches when a symlink becomes a directory" do
        FileUtils.mkdir_p("elsewhere")
        File.symlink("elsewhere", "tools")
        prime
        make_directory("tools")

        expect_both_caches_to_match_cold("b.rb call.undefined-method")
      end
    end
  end

  # rigor-dry-validation refines a Contract's `params` block through rigor-dry-schema's walker, so its
  # project loads both. rigor-dry-schema's walk records the same `lib` membership row, so that example
  # passes on either plugin's row: it pins the user-visible outcome, and
  # `spec/integration/plugins/dry_graphql_io_boundary_rows_spec.rb` pins rigor-dry-validation's own row.
  {
    "rigor-dry-schema" => {
      plugins: { "rigor-dry-schema" => "dry-schema" },
      definition: "UserSchema = Dry::Schema.Params do\n  required(:name).filled(:string)\nend\n",
      use: "UserSchema.call({}).to_h.fetch(:name).bogus_meth\n"
    },
    "rigor-dry-validation" => {
      plugins: { "rigor-dry-schema" => "dry-schema", "rigor-dry-validation" => "dry-validation" },
      definition: "class NewUserContract < Dry::Validation::Contract\n  params do\n    " \
                  "required(:name).filled(:string)\n  end\nend\n",
      use: "NewUserContract.new.call({}).to_h.fetch(:name).bogus_meth\n"
    }
  }.each do |gem_name, project|
    it "drops both run-result caches once an excluded file declares a #{gem_name} shape" do
      Rigor::Plugin.register(Rigor::Plugin::DrySchema)
      Rigor::Plugin.register(Rigor::Plugin::DryValidation) if project[:plugins].key?("rigor-dry-validation")
      write_project(project[:plugins].map { |gem, id| "  - gem: #{gem}\n    id: #{id}\n" }.join)
      File.write("lib/b.rb", project[:use])
      prime
      File.write("lib/gen/defs.rb", project[:definition])

      expect_both_caches_to_match_cold("b.rb call.undefined-method")
    end
  end
end
