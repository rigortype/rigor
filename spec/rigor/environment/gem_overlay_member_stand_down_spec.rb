# frozen_string_literal: true

# Issue #2974 — the #2422 member stand-down, extended from the plugins' `sig/` to the ADR-72 gem overlays.
#
# `data/gem_overlay/activesupport/core_ext.rbs` used to load as one of the project's own signature files, so a
# project `sig/` that redeclared one of its methods (`Integer#ordinalize`, or `ActiveSupport::NumericWithFormat
# #to_fs`, which #2973 moved into a module) made `RBS::DefinitionBuilder` raise `DuplicatedMethodDefinitionError`:
# Integer collapsed to `Dynamic[top]`, and `1.nope` went quiet. The overlay is now deferred with the plugins'
# files, so each such member stands down to the project's declaration and the rest of the overlay still loads.
#
# The assertions are positive for the reason `gem_overlay_stand_down_spec.rb` records: a collapsed class produces
# zero diagnostics, so each example pins a type that must resolve alongside the diagnostic that must fire.
require "spec_helper"
require "tmpdir"
require "fileutils"

unless defined?(AS_MEMBER_STAND_DOWN_PLUGIN_LIB)
  AS_MEMBER_STAND_DOWN_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-activesupport-core-ext/lib", __dir__)
end
$LOAD_PATH.unshift(AS_MEMBER_STAND_DOWN_PLUGIN_LIB) unless $LOAD_PATH.include?(AS_MEMBER_STAND_DOWN_PLUGIN_LIB)
require "rigor-activesupport-core-ext"

# Re-registers what an earlier spec file's `Rigor::Plugin.unregister!` cleared; see the twin constant in
# `gem_overlay_stand_down_spec.rb` for why the `require` above is not enough.
AS_MEMBER_STAND_DOWN_PLUGIN_REQUIRER = lambda do |_name|
  Rigor::Plugin.register(Rigor::Plugin::ActivesupportCoreExt)
  true
end

RSpec.describe "issue #2974 gem-overlay member stand-down" do
  def gemfile_lock
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (7.1.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        activesupport

      BUNDLED WITH
         2.5.6
    LOCK
  end

  def write_project(dir, project_rbs)
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "Gemfile.lock"), gemfile_lock)
    File.write(File.join(dir, "sig", "workaround.rbs"), project_rbs) if project_rbs
    File.write(File.join(dir, "code.rb"), <<~RUBY)
      Rigor.dump_type(1.ordinalize)
      Rigor.dump_type(1.to_fs)
      Rigor.dump_type(1.5.to_fs)
      Rigor.dump_type("user_account".camelize)
      1.nope
    RUBY
  end

  def run_project(project_rbs, plugins: [])
    Dir.mktmpdir("rigor-overlay-member-stand-down-") do |dir|
      write_project(dir, project_rbs)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => [File.join(dir, "code.rb")],
          "signature_paths" => [File.join(dir, "sig")],
          "plugins" => plugins,
          "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
        )
        guarded_run(
          Rigor::Analysis::Runner.new(
            configuration: configuration, cache_store: nil, plugin_requirer: AS_MEMBER_STAND_DOWN_PLUGIN_REQUIRER
          )
        )
      end
    end
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map { |d| d.message.sub("dump_type: ", "") }
  end

  def undefined_methods(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:method_name)
  end

  def build_failures(result)
    result.diagnostics.select { |d| d.rule == "rbs.coverage.definition-build-failed" }
  end

  def expect_typed(result, expected)
    expect(build_failures(result)).to be_empty
    expect(dumps(result)).to eq(expected)
    expect(undefined_methods(result)).to eq(["nope"])
  end

  # The workaround a project wrote before Rigor covered the method: the overlay's own signature, copied.
  it "keeps Integer typed when the project's sig/ redeclares Integer#ordinalize" do
    result = run_project("class Integer\n  def ordinalize: () -> String\nend\n")

    expect_typed(result, %w[String String String String])
  end

  it "keeps Integer and Float typed when the project's sig/ redeclares a NumericWithFormat module method" do
    result = run_project(<<~RBS)
      module ActiveSupport
        module NumericWithFormat
          def to_fs: (?Symbol format) -> Symbol
        end
      end
    RBS

    expect_typed(result, %w[String Symbol Symbol String])
  end

  it "uses the project's declaration when its signature differs from the overlay's" do
    result = run_project("class Integer\n  def ordinalize: () -> Symbol\nend\n")

    expect_typed(result, %w[Symbol String String String])
  end

  # Guard: the plugin's `sig/` was already deferred (#2422), and with the plugin loaded the overlay stands down
  # whole (#672), so this route never failed. Pinned so the overlay's new route cannot regress it.
  it "keeps the plugins: route standing down to the project's declaration" do
    entry = { "gem" => "rigor-activesupport-core-ext", "id" => Rigor::Plugin::ActivesupportCoreExt.manifest.id }
    result = run_project("class Integer\n  def ordinalize: () -> Symbol\nend\n", plugins: [entry])

    expect_typed(result, %w[Symbol String String String])
  end

  # Guard: with nothing redeclared, the overlay's own declarations bind, as before.
  it "leaves a project that redeclares nothing unchanged" do
    result = run_project(nil)

    expect_typed(result, %w[String String String String])
  end
end
