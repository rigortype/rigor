# frozen_string_literal: true

# The `core_ext/enumerable` and `core_ext/array` selectors the ADR-72 overlay
# (`data/gem_overlay/activesupport/core_ext.rbs`) had not declared. `Enumerable#many?` is the one found in
# the wild, probing #1321: `posts.to_a.many?` in a Rails app drew `call.undefined-method ... for Array[...]`
# on correct code. Comparing the overlay against ActiveSupport 8.1's `core_ext/enumerable.rb` and
# `core_ext/array/*.rb` turned up `in_order_of`, `second_to_last`, `third_to_last`, `extract_options!`
# and `Hash#extractable_options?` missing by the same omission.
#
# Every example pins a resolved TYPE next to the absent diagnostic: a duplicate declaration collapses the
# class to `Dynamic[top]`, which reports nothing, so an absence-only assertion passes on the wreck (#672).
require "spec_helper"
require "tmpdir"

RSpec.describe "ADR-72 ActiveSupport overlay — core_ext/enumerable and core_ext/array" do
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
    Dir.mktmpdir("rigor-as-overlay-enumerable-") do |dir|
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

  def undefined_methods(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:method_name)
  end

  it "resolves many? with and without a block, on Array, Hash, Range and Set receivers" do
    result = run_source(<<~RUBY)
      Rigor.dump_type([1, 2].many?)
      Rigor.dump_type([1, 2].many? { |n| n > 1 })
      Rigor.dump_type({ a: 1 }.many? { |k, v| v > 0 })
      Rigor.dump_type((1..3).many?)
      Rigor.dump_type(Set[1].many?)
    RUBY

    expect(undefined_methods(result)).to be_empty
    expect(dumps(result)).to eq(%w[bool bool bool bool bool])
  end

  it "types the Array and Enumerable readers by their element" do
    result = run_source(<<~RUBY)
      xs = [1, 2, 3].map { |n| n * 2 }
      Rigor.dump_type(xs.in_order_of(:itself, [4, 2]))
      Rigor.dump_type(xs.in_order_of(:itself, [4, 2], filter: false))
      Rigor.dump_type(xs.second_to_last)
      Rigor.dump_type(xs.third_to_last)
      Rigor.dump_type([1, { a: 1 }].extract_options!)
      Rigor.dump_type({ a: 1 }.extractable_options?)
    RUBY

    expect(undefined_methods(result)).to be_empty
    expect(dumps(result)).to eq(
      ["Array[2 | 4 | 6]", "Array[2 | 4 | 6]", "2 | 4 | 6 | nil", "2 | 4 | 6 | nil",
       "Hash[Dynamic[top], Dynamic[top]]", "bool"]
    )
  end

  # The must-still-fire sibling. `Enumerable` is included by every collection, so a row that took the
  # module down would silence every method on all of them at once.
  it "still reports a genuinely undefined method on the receivers it just opened" do
    result = run_source(<<~RUBY)
      Rigor.dump_type([1, 2].size)
      [1, 2].many_things?
      { a: 1 }.no_such_method_here
      (1..3).no_such_method_here
    RUBY

    expect(dumps(result)).to eq(["2"])
    expect(undefined_methods(result)).to eq(%w[many_things? no_such_method_here no_such_method_here])
  end

  # A project that does not lock activesupport sees the real `NoMethodError` Ruby would raise.
  it "leaves many? undefined when activesupport is not locked" do
    result = Dir.mktmpdir("rigor-as-overlay-enumerable-bare-") do |dir|
      File.write(File.join(dir, "code.rb"), "[1, 2].many?\n")
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new("paths" => [File.join(dir, "code.rb")])
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end

    expect(undefined_methods(result)).to eq(%w[many?])
  end
end
