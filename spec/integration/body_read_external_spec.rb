# frozen_string_literal: true

# Issue #3282 — a module the project declares, whose every declaring body was read and which wrote nothing under
# the name, no longer declines a read that passes it. Such a module is an EXTERNAL chain entry by construction
# (#2094): it records no `def` of its own, so the chain holds it under its spelling, and the external rule treats
# it like an RBS-unknown gem ancestor that may be the definer Ruby calls.
#
# A concern whose whole body is an `included do` block is exactly that shape once #3015 stopped filing the block's
# `def self.x` on the concern. Mastodon's `Paginable` is the live case: every instance read on the twenty-odd
# models that include it typed `Dynamic`.
#
# The read has to PASS the module, so the method it finds must be declared further along the chain than the
# body-less one: `external_may_answer?` only asks about entries between the receiver and the answer. A method on
# the includer itself answers at position 0 with nothing ahead of it, which declines nowhere and pins nothing —
# the first draft of this file made that mistake and passed identically on the engine it was meant to gate. So the
# includer mixes `Donor` in FIRST and the body-less module LAST: Ruby's `ancestors` puts the latest `include`
# nearest, so the body-less entry sits between the receiver and `Donor#mine`.
#
# Each example calls `.zork` on the result: a read that types reports `undefined method 'zork' for <type>`, and a
# read that declines reports nothing at all. So an empty expectation is a decline, which is what every control
# here asserts.
#
# Each concern sits in its own `lib/` file and the includer in another. `sig/` declares the includer and `Donor`
# with no members, and does NOT declare the module under test: a concern in a Rails app has no RBS, and an
# RBS-declared module is answered by RBS before the external rule is reached, so declaring it makes every example
# pass whatever the engine does. One control declares it, which is the point of that control.

require "spec_helper"
require "fileutils"
require "tmpdir"
require "stringio"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a read past a project module whose body was read (#3282)" do
  around do |example|
    Dir.mktmpdir("rigor-body-read-external-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # `files` maps `lib/` file names to their source. `sig/` declares every class and module the sources open, with
  # no members, unless `declare:` leaves a name out — a name RBS does not declare at all.
  def write_project(files, calls, declare: nil, members: {})
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    declared = files.values.flat_map { |body| body.scan(/^\s*(class|module) ([\w:]+)/) }.uniq
    declared = declared.select { |_, name| declare.include?(name) } if declare
    sig = declared.map { |kind, name| "#{kind} #{name}\n#{members[name]}end\n" }.join
    File.write(File.join("sig", "types.rbs"), sig)
    files.each { |name, body| File.write(File.join("lib", name), body) }
    File.write(File.join("lib", "use.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0)
    )
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message).sort
  end

  # A concern with NO def of its own: `body` is all it holds.
  def concern(name, body) = "module #{name}\n  extend ActiveSupport::Concern\n#{body}end\n"

  def hook_block(body) = "  included do\n#{body}  end\n"

  # `Donor` holds the `def` the read finds. The includer mixes it in first and `mixin` last, so `mixin` is the
  # nearer ancestor and the read of `mine` passes it on the way to `Donor`.
  def donor = "module Donor\n  def mine = 7\nend\n"

  # Everything but the module under test, which a Rails concern has no RBS for.
  def project_only = %w[Kx Donor]

  def includer(name, mixin) = "class #{name}\n  include Donor\n  include #{mixin}\nend\n"

  # The Paginable shape: scopes and a `def self.x`, all inside the block, and nothing else in the module.
  let(:paginable_shape) { hook_block("    def self.listed = 3\n") }

  it "types a read past a concern whose whole body is an included block" do
    write_project({ "0_donor.rb" => donor,
                    "a_pg.rb" => concern("Pg", paginable_shape), "k.rb" => includer("Kx", "Pg") },
                  ["Kx.new.mine.zork"], declare: project_only)
    expect(undefined_messages).to eq(["undefined method `zork' for 7"])
  end

  # Coverage, not a pin: this shape types on `master` too, because a reopening files the module's own body entry.
  # It is here so that a change which breaks the multi-file case is caught.
  it "types a read past such a concern reopened in another file, both bodies read" do
    write_project({ "0_donor.rb" => donor,
                    "a_pg.rb" => concern("Pg", ""), "b_reopen.rb" => "module Pg\n#{paginable_shape}end\n",
                    "k.rb" => includer("Kx", "Pg") }, ["Kx.new.mine.zork"], declare: project_only)
    expect(undefined_messages).to eq(["undefined method `zork' for 7"])
  end

  it "types a read past an empty project module, which records nothing at all" do
    write_project({ "0_donor.rb" => donor, "a_pm.rb" => "module Pm\nend\n", "k.rb" => includer("Kx", "Pm") },
                  ["Kx.new.mine.zork"], declare: project_only)
    expect(undefined_messages).to eq(["undefined method `zork' for 7"])
  end

  describe "the reads it must still decline" do
    # Clause 1 (an RBS-known name leaves `declared_name` nil, so the skip never applies) has NO example here,
    # because it has no observable consequence to pin: an RBS declaration with no members says the module lacks
    # the name, which never blocked the read on any engine, and one that DECLARES the name does not block it
    # either — measured on `master` and on this branch alike, the read still takes the donor's `def`. That is
    # pre-existing behaviour this change does not touch, and an example asserting a decline would fail on both.
    it "declines where the concern's hook block defines the name the read looks up" do
      # The block's `def mine` lands on the includer, and the concern's bucket holds `[:instance, :mine]`, so this
      # module may be the definer of exactly this name.
      write_project({ "0_donor.rb" => donor,
                      "a_pg.rb" => concern("Pg", hook_block("    def mine = 3\n")), "k.rb" => includer("Kx", "Pg") },
                    ["Kx.new.mine.zork"], declare: project_only)
      expect(undefined_messages).to be_empty
    end

    it "declines where the module rewrites its own method table under a name no argument spells" do
      write_project({ "0_donor.rb" => donor,
                      "a_pg.rb" => concern("Pg", "  class_eval(code)\n"), "k.rb" => includer("Kx", "Pg") },
                    ["Kx.new.mine.zork"], declare: project_only)
      expect(undefined_messages).to be_empty
    end

    it "declines where the module's side holds names no table spells" do
      write_project({ "0_donor.rb" => donor,
                      "a_pg.rb" => concern("Pg", "  attr_accessor(*NAMES)\n"), "k.rb" => includer("Kx", "Pg") },
                    ["Kx.new.mine.zork"], declare: project_only)
      expect(undefined_messages).to be_empty
    end
  end
end
