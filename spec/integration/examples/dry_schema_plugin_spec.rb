# frozen_string_literal: true

# Integration spec for `examples/rigor-dry-schema/`.
# ADR-12 + the slicing plan in
# `docs/design/20260517-dry-validation-slicing.md`.
#
# Slice 1 contract:
#
# 1. Walk the project for `Foo = Dry::Schema.{Params,JSON,define} { ... }`
#    assignments.
# 2. Inside each block, extract `required(:key).<predicate>(...)` and
#    `optional(:key).<predicate>(...)` rows.
# 3. Publish the resulting per-schema typed-key table as the
#    `:dry_schema_table` ADR-9 cross-plugin fact.

require "spec_helper"

DRY_SCHEMA_PLUGIN_LIB = File.expand_path("../../../examples/rigor-dry-schema/lib", __dir__)
$LOAD_PATH.unshift(DRY_SCHEMA_PLUGIN_LIB) unless $LOAD_PATH.include?(DRY_SCHEMA_PLUGIN_LIB)
require "rigor-dry-schema"

DRY_TYPES_PLUGIN_LIB_FOR_SCHEMA = File.expand_path("../../../examples/rigor-dry-types/lib", __dir__)
$LOAD_PATH.unshift(DRY_TYPES_PLUGIN_LIB_FOR_SCHEMA) unless $LOAD_PATH.include?(DRY_TYPES_PLUGIN_LIB_FOR_SCHEMA)
require "rigor-dry-types"

RSpec.describe "rigor-dry-schema integration" do
  let(:plugin_class) { Rigor::Plugin::DrySchema }

  let(:dry_schema_rbs) do
    <<~RBS
      module Dry
        module Schema
          def self.Params: () { (untyped) -> void } -> untyped
          def self.JSON: () { (untyped) -> void } -> untyped
          def self.define: () { (untyped) -> void } -> untyped
        end
      end
    RBS
  end

  it "registers a manifest publishing :dry_schema_table" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("dry-schema")
    expect(manifest.produces).to include(:dry_schema_table)
  end

  it "publishes the per-schema typed-key table for `Dry::Schema.Params`" do
    demo = <<~RUBY
      NewUserSchema = Dry::Schema.Params do
        required(:email).filled(:string)
        required(:age).value(:integer)
        optional(:nickname).maybe(:string)
      end
    RUBY
    table = run_and_read_fact(demo: demo)
    expect(table).not_to be_nil
    shape = table.fetch("NewUserSchema")
    expect(shape.fetch(:required)).to eq(
      email: { type: "String", list: false },
      age: { type: "Integer", list: false }
    )
    expect(shape.fetch(:optional)).to eq(nickname: { type: "String", list: false })
  end

  it "recognises `Dry::Schema.JSON` and `Dry::Schema.define` entry points" do
    demo = <<~RUBY
      JsonSchema = Dry::Schema.JSON do
        required(:sku).filled(:string)
      end

      RawSchema = Dry::Schema.define do
        required(:foo).value(:integer)
      end
    RUBY
    table = run_and_read_fact(demo: demo)
    expect(table.fetch("JsonSchema").fetch(:required)).to eq(sku: { type: "String", list: false })
    expect(table.fetch("RawSchema").fetch(:required)).to eq(foo: { type: "Integer", list: false })
  end

  it "registers class-level schema constants under the enclosing constant chain" do
    demo = <<~RUBY
      module App
        module Schemas
          UserCreate = Dry::Schema.Params do
            required(:email).filled(:string)
          end
        end
      end
    RUBY
    table = run_and_read_fact(demo: demo)
    expect(table).to have_key("App::Schemas::UserCreate")
    expect(table.fetch("App::Schemas::UserCreate").fetch(:required))
      .to eq(email: { type: "String", list: false })
  end

  it "maps every dry-schema canonical-type symbol the slice-1 vocabulary supports" do
    demo = <<~RUBY
      EverythingSchema = Dry::Schema.Params do
        required(:a).filled(:string)
        required(:b).filled(:integer)
        required(:c).filled(:float)
        required(:d).filled(:decimal)
        required(:e).filled(:symbol)
        required(:f).filled(:bool)
        required(:g).filled(:nil)
        required(:h).filled(:date)
        required(:i).filled(:date_time)
        required(:j).filled(:time)
        required(:k).filled(:hash)
        required(:l).filled(:array)
      end
    RUBY
    table = run_and_read_fact(demo: demo)
    req = table.fetch("EverythingSchema").fetch(:required)
    expect(req.transform_values { |v| v[:type] }).to eq(
      a: "String", b: "Integer", c: "Float", d: "BigDecimal",
      e: "Symbol", f: "TrueClass", g: "NilClass",
      h: "Date", i: "DateTime", j: "Time",
      k: "Hash", l: "Array"
    )
    expect(req.values.map { |v| v[:list] }.uniq).to eq([false])
  end

  it "drops keys whose type symbol isn't in the canonical vocabulary" do
    demo = <<~RUBY
      Schema = Dry::Schema.Params do
        required(:known).filled(:string)
        required(:bogus).filled(:not_a_type)
      end
    RUBY
    shape = run_and_read_fact(demo: demo).fetch("Schema")
    expect(shape.fetch(:required)).to eq(known: { type: "String", list: false })
  end

  it "resolves user-authored constant references through the :dry_type_aliases fact" do
    demo = <<~RUBY
      module Types
        include Dry.Types()

        Email = String.constrained(format: /@/)
      end

      ContactSchema = Dry::Schema.Params do
        required(:email).value(Types::Email)
        required(:name).filled(:string)
      end
    RUBY
    table = run_and_read_fact(demo: demo, with_dry_types: true)
    shape = table.fetch("ContactSchema")
    expect(shape.fetch(:required)).to eq(
      email: { type: "String", list: false },
      name: { type: "String", list: false }
    )
  end

  it "drops constant-type references when :dry_type_aliases isn't published" do
    demo = <<~RUBY
      UnresolvedSchema = Dry::Schema.Params do
        required(:email).value(Types::Email)
        required(:name).filled(:string)
      end
    RUBY
    # No `Types` module + no rigor-dry-types loaded → the constant
    # reference doesn't resolve, key drops.
    shape = run_and_read_fact(demo: demo).fetch("UnresolvedSchema")
    expect(shape.fetch(:required)).to eq(name: { type: "String", list: false })
  end

  it "marks `each(<Type>)` predicates as list-typed (slice 2)" do
    demo = <<~RUBY
      Schema = Dry::Schema.Params do
        required(:tags).each(:string)
        required(:scores).value(:array)
        optional(:authors).each(:string)
      end
    RUBY
    shape = run_and_read_fact(demo: demo).fetch("Schema")
    expect(shape.fetch(:required)).to eq(
      tags: { type: "String", list: true },
      scores: { type: "Array", list: false }
    )
    expect(shape.fetch(:optional)).to eq(authors: { type: "String", list: true })
  end

  it "does NOT publish the fact when no `Dry::Schema.X` declaration is present" do
    demo = <<~RUBY
      class Foo
        def bar; "noop"; end
      end
    RUBY
    expect(run_and_read_fact(demo: demo)).to be_nil
  end

  # Runs the plugin(s) against a single-file project and returns
  # the `:dry_schema_table` fact value. Optionally also loads
  # rigor-dry-types (for the cross-plugin fact-resolution test).
  def run_and_read_fact(demo:, with_dry_types: false)
    Rigor::Plugin.unregister!
    captured_store = capture_fact_store!
    plugin_entries = with_dry_types ? %w[rigor-dry-types rigor-dry-schema] : ["rigor-dry-schema"]

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "schema.rb"), demo)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "dry_schema.rbs"), dry_schema_rbs)
      run_analysis(dir: dir, plugin_entries: plugin_entries)
    end
    captured_store.call&.read(plugin_id: "dry-schema", name: :dry_schema_table)
  end

  def capture_fact_store!
    captured = nil
    allow(Rigor::Plugin::Services).to receive(:new).and_wrap_original do |original, **kwargs|
      services = original.call(**kwargs)
      captured = services.fact_store
      services
    end
    -> { captured }
  end

  def run_analysis(dir:, plugin_entries:)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => [File.join(dir, "schema.rb")],
        "plugins" => plugin_entries
      )
    )

    Dir.chdir(dir) do
      Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: nil,
        plugin_requirer: lambda do |name|
          case name
          when "rigor-dry-types" then Rigor::Plugin.register(Rigor::Plugin::DryTypes)
          when "rigor-dry-schema" then Rigor::Plugin.register(Rigor::Plugin::DrySchema)
          end
          true
        end
      ).run
    end
  end
end
