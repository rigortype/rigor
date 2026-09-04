# frozen_string_literal: true

# Issue #736 — `mattr_accessor` / `cattr_accessor` / `class_attribute` introduce methods on both sides of
# the class, and discovery has to record them or `call.undefined-method` fires on working code.
#
# The failure is invisible until a `sig/` exists: an undeclared receiver is not a receiver the rule can
# speak about. The moment one does — hand-written, or written by `rigor sig-gen --write`, which declares
# every module it can type a method in — every call to a DSL-introduced accessor starts reporting. On
# redmine that was 37 of the 82 firings a generated `sig/` added over the project's own baseline.
#
# The names are ActiveSupport's, but the table lives in the engine's walk: the consumer is the cross-file
# `discovered_methods` table, and no plugin surface reaches it (the ADR-16 synthetic-method tier feeds the
# dispatcher, which the check rules do not consult).

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "module attribute macros and call.undefined-method (#736)" do
  def write_project(declaration:, calls:)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    # The partial sidecar that makes the module RBS-known without declaring the accessors — the shape
    # `sig-gen --write` produces, and the precondition for the rule to fire at all.
    File.write(File.join("sig", "search.rbs"), "module Search\nend\n")
    File.write(File.join("lib", "search.rb"), "module Search\n  #{declaration}\nend\n")
    File.write(File.join("lib", "caller.rb"), "def run\n#{calls.map { |c| "  #{c}" }.join("\n")}\nend\n")
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0
      )
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-module-attribute-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "records mattr_accessor on both sides" do
    # Both sides, because `mattr_accessor` defines the singleton reader/writer AND the instance pair. A
    # fixture calling only `Search.x` would pass against a singleton-only recorder.
    write_project(
      declaration: "mattr_accessor :available_types",
      calls: ["Search.available_types", "Search.available_types = []"]
    )
    expect(undefined_messages).to be_empty
  end

  it "records the reader-only and writer-only spellings for their own half" do
    write_project(
      declaration: "cattr_reader :registry\n  cattr_writer :sink",
      calls: ["Search.registry", "Search.sink = 1"]
    )
    expect(undefined_messages).to be_empty
  end

  it "records class_attribute's predicate alongside its accessor" do
    write_project(
      declaration: "class_attribute :enabled",
      calls: ["Search.enabled", "Search.enabled = true", "Search.enabled?"]
    )
    expect(undefined_messages).to be_empty
  end

  it "still fires for a name no macro introduces" do
    # Mandatory must-still-fire: the macros suppress the names they define, not the class. Without this
    # arm a recogniser that marked the whole module unknown would pass every example above.
    write_project(
      declaration: "mattr_accessor :available_types",
      calls: %w[Search.available_types Search.no_such_thing]
    )
    expect(undefined_messages).to eq(["undefined method `no_such_thing' for singleton(Search)"])
  end

  it "does not record a macro called on an explicit receiver" do
    # `Other.mattr_accessor :x` is not the implicit-self macro and does not define anything on `Search`.
    # Mirrors the guard `record_attr_methods` has carried since it was written.
    write_project(
      declaration: "Object.mattr_accessor :elsewhere",
      calls: ["Search.elsewhere"]
    )
    # The second message is the fixture's own doing and is asserted rather than filtered: with no
    # ActiveSupport in the environment, `Object.mattr_accessor` is itself an undefined call. Its presence
    # also proves the fixture reaches the rule, so the first message is not an artifact of a dead path.
    expect(undefined_messages).to eq(
      ["undefined method `elsewhere' for singleton(Search)",
       "undefined method `mattr_accessor' for singleton(Object)"]
    )
  end
end
