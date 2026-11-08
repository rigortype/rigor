# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #2969 — `NumericWithFormat#to_fs` / `#to_formatted_s` on Integer, Float and BigDecimal.
#
# The ADR-72 overlay (`data/gem_overlay/activesupport/core_ext.rbs`) is the copy that applies when
# `activesupport` is locked and the plugin is not enabled; the plugin is its opt-in twin, and the parity guard
# in `activesupport_overlay_parity_spec.rb` keeps the overlay declaring every selector the plugin does. So the
# same expressions are quiet on a project that locks activesupport. A project that locks nothing gets no
# overlay, and `1.to_fs` stays a genuine `call.undefined-method`, as the overlay header promises.
#
# Every example pins the resolved TYPE next to the absent diagnostic (see the hash/range spec, #672).
require "spec_helper"

RSpec.describe "ADR-72 ActiveSupport overlay — NumericWithFormat#to_fs (#2969)" do
  def gemfile_lock
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          activesupport (8.1.3)

      PLATFORMS
        ruby

      DEPENDENCIES
        activesupport

      BUNDLED WITH
         2.5.6
    LOCK
  end

  # `project_sig` is RBS text written to a project `sig/` directory and named as `signature_paths:`, the way a
  # project working around #2969 would declare `Integer#to_fs` itself.
  def run_source(source, lock: true, project_sig: nil)
    Dir.mktmpdir("rigor-as-overlay-numeric-") do |dir|
      File.write(File.join(dir, "Gemfile.lock"), gemfile_lock) if lock
      File.write(File.join(dir, "code.rb"), source)
      signature_paths = []
      if project_sig
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig", "project.rbs"), project_sig)
        signature_paths = [File.join(dir, "sig")]
      end
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => [File.join(dir, "code.rb")],
          "signature_paths" => signature_paths,
          "bundler" => { "lockfile" => "Gemfile.lock", "auto_detect" => true }
        )
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map { |d| d.message.sub("dump_type: ", "") }
  end

  def call_rules(result)
    result.diagnostics.map(&:qualified_rule).grep(/\Acall\./)
  end

  def undefined_methods(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
  end

  # Every receiver class and both selectors, and every argument form the source accepts: no format (`to_s`),
  # an Integer radix, a String, a Symbol format with and without options. All answer a String.
  it "answers a String for to_fs and to_formatted_s on Integer, Float and BigDecimal, quietly" do
    result = run_source(<<~RUBY)
      require "bigdecimal"
      Rigor.dump_type(1.to_fs)
      Rigor.dump_type(1.to_fs(2))
      Rigor.dump_type(1.to_fs(:delimited))
      Rigor.dump_type(1.to_fs(:currency, precision: 3))
      Rigor.dump_type(1.5.to_formatted_s(:percentage))
      Rigor.dump_type(2.5.to_fs(:human_size))
      Rigor.dump_type(BigDecimal("1.5").to_fs(:rounded, precision: 1))
      Rigor.dump_type(BigDecimal("1.5").to_formatted_s)
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(Array.new(8, "String"))
  end

  it "answers to_fs on BigDecimal under the overlay, with a typed String" do
    result = run_source(<<~RUBY)
      require "bigdecimal"
      Rigor.dump_type(BigDecimal("1.5").to_fs(:delimited))
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(["String"])
  end

  # Gating: with no activesupport lock the overlay does not load, so the call is a real diagnostic on a project
  # that does not use ActiveSupport. Pinned so that a wider overlay (one that answered `to_fs` everywhere) is a
  # deliberate change, not a side effect.
  it "still reports to_fs when the project locks no activesupport" do
    result = run_source(<<~RUBY, lock: false)
      Rigor.dump_type(1.to_fs(:delimited))
    RUBY

    expect(undefined_methods(result).join).to include("to_fs")
  end

  # Review of #2973 (severe): ActiveSupport calls `options.symbolize_keys`, so a String-keyed Hash is a valid
  # options argument. The earlier `Hash[Symbol, untyped]` reported `call.argument-type-mismatch` on it.
  it "accepts a String-keyed options Hash, which ActiveSupport symbolizes itself" do
    result = run_source(<<~RUBY)
      opts = { "precision" => 2 }
      Rigor.dump_type(1.to_fs(:rounded, opts))
      Rigor.dump_type(1.5.to_fs(:percentage, { "precision" => 1 }))
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(%w[String String])
  end

  # Review of #2973 (moderate): a project `sig/` that declares `Integer#to_fs` itself is the natural workaround
  # for #2969. The overlay declared `to_fs` directly on Integer, so that pair was a `DuplicatedMethodDefinitionError`
  # and Integer collapsed to `Dynamic[top]`, losing `1.nope`. Declaring the methods on the module that Integer
  # includes lets the project's own declaration win.
  it "keeps Integer typed and reporting when a project sig declares Integer#to_fs itself" do
    result = run_source(<<~RUBY, project_sig: <<~RBS)
      Rigor.dump_type(1.to_fs(:delimited))
      1.nope
    RUBY
      class Integer
        def to_fs: (*untyped) -> String
      end
    RBS

    expect(dumps(result)).to eq(["String"])
    expect(undefined_methods(result).join).to include("nope")
  end
end
