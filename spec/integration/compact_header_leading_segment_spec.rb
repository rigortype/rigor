# frozen_string_literal: true

# Issue #722 residue 2 — a COMPACT header's LEADING segment resolves through the nesting, with a top-level
# fall-through.
#
# `class Outer::Leaf` inside `module Wrap` was keyed `Wrap::Outer::Leaf` by the per-node
# `Source::ConstantPath.declaration_prefix`. Ruby resolves the leading `Outer` by ordinary constant lookup:
# with no `Wrap::Outer`, the header reopens `::Outer::Leaf`. The mis-keying was invisible rather than wrong —
# a receiver that resolves to a class nobody declared answers `untyped`, so a `.nope` on it reported nothing
# at all (the #665 shape). Asserting the constant resolves is therefore necessary but NOT sufficient; the
# decline arm below asserts the diagnostic FIRES.
#
# The re-anchoring is adjudicated once, where the whole project's declared names are known
# (`ScopeIndexer#compact_header_renames`), because whether `Wrap::Outer` exists is not a per-node fact. It
# moves a declaration only when the project answers both halves of Ruby's lookup — no `Wrap::Outer` anywhere
# in source AND a top-level `Outer` that IS declared there. A namespace that merely never appears in project
# source (a gem, an RBS-only class) still exists at runtime, and re-anchoring on its absence would answer
# with a wrong class where the mis-keying only answered with silence.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a compact header's leading segment (#722 residue 2)" do
  def diagnostics_for(source, signature = nil)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    if signature
      FileUtils.mkdir_p("sig")
      File.write(File.join("sig", "demo.rbs"), signature)
    end
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    ).diagnostics
  end

  def dumps_for(source)
    diagnostics_for(source).select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-compact-header-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "reopens the top-level class when the nesting supplies no such namespace" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :added", "dump_type: :base"])
      class Outer; end

      class Outer::Leaf
        def base = :base
      end

      module Wrap
        class Outer::Leaf
          def added = :added
        end
      end

      def probe = Rigor.dump_type(Outer::Leaf.new.added)
      def control = Rigor.dump_type(Outer::Leaf.new.base)
    RUBY
  end

  it "fires on an unknown method of the reopened class" do
    # The must-FIRE arm, written from INSIDE the enclosing namespace — the position the mis-keying survived
    # longest, because the lexical ladder finds `Wrap::Outer::Leaf` there before it ever tries the top level.
    # Before the re-anchoring the receiver resolved to a class no declaration produced, so the call typed
    # `untyped` and NOTHING was reported: silence on both arms is how this hid. The signature is what makes
    # the class closed enough for the rule to fire at all — so the surviving method answers the SIGNATURE's
    # `Symbol` rather than the body's `:base`, and that dump is the must-still-succeed counterpart proving
    # the receiver resolved rather than merely going quiet.
    source = <<~RUBY
      class Outer; end

      class Outer::Leaf
        def base = :base
      end

      module Wrap
        class Outer::Leaf
          def added = :added
        end

        def self.bad = Outer::Leaf.new.nope
        def self.ok = Rigor.dump_type(Outer::Leaf.new.base)
      end
    RUBY
    signature = <<~RBS
      class Outer
      end

      class Outer::Leaf
        def base: () -> Symbol
        def added: () -> Symbol
      end
    RBS
    diagnostics = diagnostics_for(source, signature)
    expect(diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)).to include(/nope/)
    expect(diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)).to eq(["dump_type: Symbol"])
  end

  it "keeps the nested class when the nesting DOES supply the namespace" do
    # The must-still-succeed arm: `Wrap::Outer` exists, so the compact header reopens `Wrap::Outer::Leaf`
    # and the top-level `Outer::Leaf` never sees `added`.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :added", "dump_type: :base"])
      class Outer; end

      class Outer::Leaf
        def base = :base
      end

      module Wrap
        module Outer; end

        class Outer::Leaf
          def added = :added
        end

        def self.probe = Rigor.dump_type(Wrap::Outer::Leaf.new.added)
      end

      def control = Rigor.dump_type(Outer::Leaf.new.base)
    RUBY
  end

  it "leaves the declaration where it is when the project declares no top-level leading segment" do
    # The false-positive bound. Nothing in project source says whether `Wrap::Outer` exists, and no
    # top-level `Outer` is declared either, so the walk keeps its per-node answer rather than inventing a
    # top-level class for the header to land in.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :added"])
      module Wrap
        class Outer::Leaf
          def added = :added
        end

        def self.probe = Rigor.dump_type(Wrap::Outer::Leaf.new.added)
      end
    RUBY
  end
end
