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

FFI_CACHE_BINDING = "module L\n  attach_function :foo, [], :int\nend\n"

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

  # Each mode in `modes` (a list of flag lists) answers what `--no-cache` answers, and that answer holds the
  # catalog-attached `foo`'s finding exactly when `attached`.
  def expect_modes_to_match_cold(modes, attached:)
    cold = rules(check("--no-cache").first)
    expect(cold.include?("b.rb call.undefined-method")).to be(attached)
    modes.each { |flags| expect(rules(check(*flags).first)).to eq(cold) }
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

    # #1959 — the walk lists the root's top-level entries with their kinds, then globs each real directory but
    # `vendor/` on its own. A top-level entry that keeps its name and changes kind changes what the walk reads,
    # so the listing row must move. `paths:` is `lib`, so only the catalog sees these files.
    context "with a top-level entry that changes kind" do
      # The symlink points outside the project at a directory holding the binding: `**` never followed a
      # symlinked directory, so the binding reaches the catalog only while the name is a real directory, and the
      # paths the walk would list under the name are the same either way.
      let(:outside) { Dir.mktmpdir("rigor-ffi-outside-") }

      before { File.write(File.join(outside, "a.rb"), FFI_CACHE_BINDING) }
      after { FileUtils.rm_rf(outside) }

      def replace(name, kind)
        FileUtils.rm_rf(name)
        case kind
        when :directory
          FileUtils.mkdir_p(name)
          File.write("#{name}/a.rb", FFI_CACHE_BINDING)
        when :file then File.write(name, "not ruby\n")
        when :symlink then File.symlink(outside, name)
        end
      end

      [
        ["a file", :file, :directory, true],
        ["a directory", :directory, :file, false],
        ["a symlink", :symlink, :directory, true],
        ["a directory", :directory, :symlink, false],
        ["a missing entry", nil, :directory, true]
      ].each do |was, from, to, attached|
        it "drops both run-result caches when #{was} named gen becomes a #{to}" do
          replace("gen", from)
          prime
          replace("gen", to)

          expect_modes_to_match_cold([["--incremental"], []], attached: attached)
        end

        it "drops the producer's own entry under --workers 2 when #{was} named gen becomes a #{to}" do
          replace("gen", from)
          2.times { check("--workers", "2") }
          replace("gen", to)

          expect_modes_to_match_cold([["--workers", "2"]], attached: attached)
        end
      end
    end

    # #1959 — `vendor/` and `.git/` are not walked, so a change there leaves the catalog and both run-result
    # caches served: a `bundle install` into an in-tree `vendor/bundle` no longer re-analyses the project.
    context "with a change under a skipped directory" do
      %w[vendor/bundle/gems/x/lib .git/hooks].each do |directory|
        it "serves both caches past a binding added under #{directory.split('/').first}/" do
          FileUtils.mkdir_p(directory)
          File.write("#{directory}/keep.rb", "")
          prime
          allow(Rigor::Plugin::FFI::Discoverer).to receive(:discover).and_call_original
          File.write("#{directory}/a.rb", FFI_CACHE_BINDING)

          expect(rules(check("--incremental").first)).to eq([])
          expect(rules(check.first)).to eq([])
          expect(Rigor::Plugin::FFI::Discoverer).not_to have_received(:discover)
          expect(rules(check("--no-cache").first)).to eq([])
        end
      end

      # The skip reads every directory segment under the root, as the whole-root walk's did.
      it "still skips a vendor/ directory below the top level" do
        prime
        FileUtils.mkdir_p("tools/vendor")
        File.write("tools/vendor/a.rb", FFI_CACHE_BINDING)

        expect_modes_to_match_cold([["--incremental"], []], attached: false)
      end
    end

    # #1959 — the walk's row re-globs its root on every validation; a root spelled with glob metacharacters matched
    # nothing there, so the row never moved.
    context "with a project path holding glob metacharacters" do
      around do |example|
        FileUtils.mkdir_p("ffi [x]{a}")
        Dir.chdir("ffi [x]{a}") { example.run }
      end

      it "drops both run-result caches once an excluded file attaches a function" do
        prime
        File.write("lib/gen/a.rb", "module L\n  attach_function :foo, [], :int\nend\n")

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
