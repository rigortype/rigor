# frozen_string_literal: true

# Issue #735 — whose RBS a class has decides what a project `def` in ANOTHER file is.
#
# ADR-17 has `call.undefined-method` report a project `def` on an RBS-declared class it does not apply
# cross-file, and point at `pre_eval:`. That is right for a BUNDLED declaration: `String`'s signature is
# authoritative, so a project `def` on it genuinely patches something the project does not own.
#
# It is wrong for the project's OWN sidecar `sig/`. There the declaration describes the very source being
# analysed, the "patch" is just the second file of an ordinary class, and the advice cannot be acted on —
# it asks the user to `pre_eval:` their own application. `rigor sig-gen --write` on redmine turned 29
# `call.undefined-method` into 171 through this reading, 49 of them here, on a `sig/` Rigor wrote itself.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a project sidecar sig and a cross-file def (#735)" do
  # Declares the class and ONE of its methods — the shape every incrementally written `sig/` has, and
  # exactly what `sig-gen` emits when it can type some methods and not others.
  def write_project(sidecar: true)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "fetcher.rbs"), <<~RBS) if sidecar
      class Fetcher
        def label: () -> String
      end
    RBS
    File.write(File.join("lib", "fetcher.rb"), <<~RUBY)
      class Fetcher
        def label = "f"
        def scope_select = 100
        def self.build = :built
      end
    RUBY
    File.write(File.join("lib", "core_ext.rb"), <<~RUBY)
      class String
        def blankish? = empty?
      end
    RUBY
    File.write(File.join("lib", "caller.rb"), <<~RUBY)
      def run
        Rigor.dump_type(Fetcher.new.scope_select)
        Rigor.dump_type(Fetcher.build)
        "x".blankish?
      end
    RUBY
  end

  def run_check
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0
      )
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def undefined_messages(result)
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  def dumps(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-project-sidecar-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not report the project's own cross-file defs, on either side" do
    write_project
    result = run_check

    # The instance side is the shape the issue counts (49 of redmine's 171); the singleton side is the
    # larger half of the rest, because a module with a class-method surface is how that codebase is built.
    expect(undefined_messages(result)).to eq(
      ["undefined method `blankish?' for \"x\"; the project defines `String#blankish?' at " \
       "lib/core_ext.rb:2 — Rigor does not apply project monkey-patches cross-file; list that file in " \
       "`.rigor.yml`'s `pre_eval:` (ADR-17)"]
    )
    # The suppression is not blindness: the calls resolve to the source's own return types.
    expect(dumps(result)).to eq(["dump_type: 100", "dump_type: :built"])
  end

  it "still reports a cross-file def on a BUNDLED class" do
    # The must-still-fire arm, and the whole point of the distinction: `String` is not the project's class,
    # its RBS is authoritative, and the ADR-17 contract for it is untouched. It is asserted in the example
    # above as the one surviving message rather than only here, so a fix that silenced everything fails
    # both. This example pins that it is the BUNDLED-ness doing the work: with no project `sig/` at all,
    # the same call reports the same thing.
    write_project(sidecar: false)
    expect(undefined_messages(run_check)).to include(
      a_string_starting_with("undefined method `blankish?' for \"x\"")
    )
  end

  it "still reports a method the project defines nowhere" do
    write_project
    File.write(File.join("lib", "caller.rb"), "def run = Fetcher.new.no_such_method\n")

    expect(undefined_messages(run_check)).to eq(
      ["undefined method `no_such_method' for Fetcher"]
    )
  end
end
