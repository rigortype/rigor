# frozen_string_literal: true

# The `core_ext/object/deep_dup`, `core_ext/hash/*` and `core_ext/range/*` selectors the ADR-72 overlay
# (`data/gem_overlay/activesupport/core_ext.rbs`) had not declared, found in the review of #1326 by diffing
# ActiveSupport 8.1's runtime `public_instance_methods` with and without `active_support/all` loaded. Most are
# `alias_method`s of rows the overlay already had (`to_options` of `symbolize_keys`, `with_defaults` of
# `reverse_merge`, `nested_under_indifferent_access` of `with_indifferent_access`, `overlaps?` of core
# `overlap?`), so the omission was invisible to a reader of the overlay. `deep_dup` sat on `Hash` alone,
# which left `[[1], [2]].deep_dup` — the common shape — a `call.undefined-method`.
#
# Every example pins a resolved TYPE next to the absent diagnostic: a duplicate declaration collapses the
# class to `Dynamic[top]`, which reports nothing, so an absence-only assertion passes on the wreck (#672).
require "spec_helper"
require "tmpdir"

RSpec.describe "ADR-72 ActiveSupport overlay — deep_dup, the Hash aliases and core_ext/range" do
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

  def run_source(source)
    Dir.mktmpdir("rigor-as-overlay-hash-range-") do |dir|
      File.write(File.join(dir, "Gemfile.lock"), gemfile_lock)
      File.write(File.join(dir, "code.rb"), source)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new(
          "paths" => [File.join(dir, "code.rb")],
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
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:method_name)
  end

  it "types deep_dup as the receiver on every receiver, not only on Hash" do
    result = run_source(<<~RUBY)
      Rigor.dump_type([[1], [2]].deep_dup)
      Rigor.dump_type("x".dup.deep_dup)
      Rigor.dump_type(Object.new.deep_dup)
      Rigor.dump_type({ a: 1 }.deep_dup)
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(["Array[Array[Integer]]", "String", "Object", "Hash[:a, 1]"])
  end

  it "types the Hash aliases like the rows they alias" do
    result = run_source(<<~RUBY)
      h = { "a" => 1 }
      Rigor.dump_type(h.to_options)
      Rigor.dump_type(h.to_options!)
      Rigor.dump_type(h.with_defaults!({ "b" => 2 }))
      Rigor.dump_type(h.reverse_update({ "b" => 2 }))
      Rigor.dump_type(h.extract!("a", "z"))
      Rigor.dump_type(h.deep_merge?({}))
      Rigor.dump_type(h.nested_under_indifferent_access)
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(
      ["Hash[Symbol, 1]", "Hash[String, Integer]", "Hash[String, Integer]", "Hash[String, Integer]",
       'Hash["a", 1]', "bool", "Dynamic[top]"]
    )
  end

  # `reverse_merge` is `other_hash.merge(self)`, so the argument's keys and values belong in the result.
  # The row answered `Hash[K, V]` — the receiver's own — until this change, so `opts[:velocity]` below
  # typed as the receiver's `1`. The argument side now reads `Dynamic[top]`: the method-level `[A, B]` is
  # not solved against these arguments. That is gradual, not precise — core `Hash#merge` folds this
  # literal receiver to the shape `{ size: 1, velocity: 10 }`, and the two agree only on a nominal
  # receiver — but it no longer claims the result holds the receiver's keys and values alone.
  it "keeps the argument's keys and values in reverse_merge and with_defaults" do
    result = run_source(<<~RUBY)
      opts = { size: 1 }
      Rigor.dump_type(opts.reverse_merge(size: 25, velocity: 10))
      Rigor.dump_type(opts.with_defaults(size: 25, velocity: 10))
      Rigor.dump_type(opts.with_defaults(size: 25, velocity: 10)[:velocity])
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(
      ["Hash[:size | Dynamic[top], 1 | Dynamic[top]]", "Hash[:size | Dynamic[top], 1 | Dynamic[top]]",
       "1 | Dynamic[top]"]
    )
  end

  it "resolves overlaps? beside core overlap?, and to_fs / to_formatted_s on a Range" do
    result = run_source(<<~RUBY)
      Rigor.dump_type((1..5).overlaps?(4..6))
      Rigor.dump_type((1..5).overlap?(4..6))
      Rigor.dump_type((1..5).to_fs(:db))
      Rigor.dump_type((1..5).to_formatted_s)
      Rigor.dump_type((1..5).each_slice(2))
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(["bool", "bool", "String", "String", "Enumerator[Array[Dynamic[top]], Range]"])
  end

  # The must-still-fire sibling. `Range` is newly reopened by the overlay and `Object` reaches every
  # receiver, so a row that collapsed either would silence these at once. The `each_slice` pin is the
  # Range control, and not `size` / `sum`: those fold a literal range before RBS dispatch, so they kept
  # answering `5` / `15` with the reopening mutated to `class Range[E]` and the class collapsed.
  it "still reports a genuinely undefined method on the receivers it just opened" do
    result = run_source(<<~RUBY)
      Rigor.dump_type((1..5).each_slice(2))
      (1..5).overlapz?(2..3)
      { a: 1 }.with_defaultz({})
      [1].deep_dupe
      Object.new.no_such_method_here
    RUBY

    expect(dumps(result)).to eq(["Enumerator[Array[Dynamic[top]], Range]"])
    expect(undefined_methods(result)).to eq(%w[overlapz? with_defaultz deep_dupe no_such_method_here])
  end

  # A project that does not lock activesupport sees the real `NoMethodError` Ruby would raise.
  it "leaves the new rows undefined when activesupport is not locked" do
    result = Dir.mktmpdir("rigor-as-overlay-hash-range-bare-") do |dir|
      File.write(File.join(dir, "code.rb"), "[1].deep_dup\n{ a: 1 }.with_defaults({})\n(1..2).overlaps?(1..2)\n")
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new("paths" => [File.join(dir, "code.rb")])
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end

    expect(undefined_methods(result)).to eq(%w[deep_dup with_defaults overlaps?])
  end
end
