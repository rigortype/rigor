# frozen_string_literal: true

# The `core_ext/object`, `core_ext/string` and `core_ext/symbol` selectors the ADR-72 overlay
# (`data/gem_overlay/activesupport/core_ext.rbs`) still had not declared after #1330, found by the same
# runtime `public_instance_methods` diff against ActiveSupport 8.1: `Object#presence_in` / `#with` /
# `#with_options` / `#html_safe?`, `String#acts_like_string?` / `#downcase_first` / `#in_time_zone` /
# `#is_utf8?`, and the `Symbol#starts_with?` / `#ends_with?` aliases.
#
# Every example pins a resolved TYPE next to the absent diagnostic: a duplicate declaration collapses the
# class to `Dynamic[top]`, which reports nothing, so an absence-only assertion passes on the wreck (#672).
require "spec_helper"
require "tmpdir"

RSpec.describe "ADR-72 ActiveSupport overlay — the Object, String and Symbol rows" do
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
    Dir.mktmpdir("rigor-as-overlay-object-string-symbol-") do |dir|
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

  it "types the Object rows, and html_safe? on a receiver that is not a String" do
    result = run_source(<<~RUBY)
      Rigor.dump_type("a".presence_in(%w[a b]))
      Rigor.dump_type(1.html_safe?)
      Rigor.dump_type(Object.new.with(timeout: 1) { |o| 1 })
      Rigor.dump_type(Object.new.with_options(presence: true) { |o| :merged })
      Rigor.dump_type(Object.new.with_options({ presence: true }) { :instance_evaled })
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(["String?", "bool", "1", ":merged", ":instance_evaled"])
  end

  # The model-body shape: `self` is the class, which reaches `Object#with_options` through `Class < Object`.
  it "resolves with_options on a class body's implicit self" do
    result = run_source(<<~RUBY)
      class Post
        with_options(dependent: :destroy) { 1 }
        Rigor.dump_type(with_options(dependent: :destroy) { 2 })
      end
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(["2"])
  end

  # Core `Data#with` is a subclass override, so the new `Object#with` row must not reach a `Data` receiver:
  # the answer stays the member-updated instance with or without a block, never the block's value.
  it "leaves core Data#with in charge of a Data receiver" do
    result = run_source(<<~RUBY)
      Point = Data.define(:x, :y)
      Rigor.dump_type(Point.new(x: 1, y: 2).with(x: 3))
      Rigor.dump_type(Point.new(x: 1, y: 2).with(x: 3) { :block })
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(["Point(x: 3, y: 2)", "Point(x: 3, y: 2)"])
  end

  it "types the String rows" do
    result = run_source(<<~RUBY)
      Rigor.dump_type("Abc".downcase_first)
      Rigor.dump_type("a".acts_like_string?)
      Rigor.dump_type("a".is_utf8?)
      "2026-01-01".in_time_zone
      "2026-01-01".in_time_zone("UTC")
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(%w[String true bool])
  end

  it "types the Symbol aliases with the core parameter lists" do
    result = run_source(<<~RUBY)
      Rigor.dump_type(:abc.starts_with?("a"))
      Rigor.dump_type(:abc.starts_with?(/a/, "b"))
      Rigor.dump_type(:abc.ends_with?("c"))
    RUBY

    expect(call_rules(result)).to be_empty
    expect(dumps(result)).to eq(%w[bool bool bool])
  end

  # The must-still-fire sibling. `Symbol` is newly reopened by the overlay and `Object` / `String` gain rows,
  # so a row that collapsed any of the three would silence these at once. Each control is a method the
  # overlay does not declare, answered through RBS dispatch rather than a literal fold, so it reads
  # `Dynamic[top]` on a collapsed class.
  it "still reports a genuinely undefined method on the receivers it just opened" do
    result = run_source(<<~RUBY)
      Rigor.dump_type(Object.new.frozen?)
      Rigor.dump_type("a".encoding)
      Rigor.dump_type(:abc.to_proc)
      Object.new.presence_inn([1])
      "a".downcase_firstt
      :abc.starts_withh?("a")
    RUBY

    expect(dumps(result)).to eq(%w[bool Encoding Proc])
    expect(undefined_methods(result)).to eq(%w[presence_inn downcase_firstt starts_withh?])
  end

  # A project that does not lock activesupport sees the real `NoMethodError` Ruby would raise.
  it "leaves the new rows undefined when activesupport is not locked" do
    source = "\"a\".presence_in([])\nObject.new.with(a: 1) { }\n\"a\".downcase_first\n:a.starts_with?(\"a\")\n"
    result = Dir.mktmpdir("rigor-as-overlay-object-string-symbol-bare-") do |dir|
      File.write(File.join(dir, "code.rb"), source)
      Dir.chdir(dir) do
        configuration = Rigor::Configuration.new("paths" => [File.join(dir, "code.rb")])
        guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      end
    end

    expect(undefined_methods(result)).to eq(%w[presence_in with downcase_first starts_with?])
  end
end
