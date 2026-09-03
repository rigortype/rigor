# frozen_string_literal: true

# Integration spec for `plugins/rigor-dry-schema/`. ADR-12 + the slicing plan in
# `docs/design/20260517-dry-validation-slicing.md`.
#
# Slice 1 contract:
#
# 1. Walk the project for `Foo = Dry::Schema.{Params,JSON,define} { ... }` assignments.
# 2. Inside each block, extract `required(:key).<predicate>(...)` and `optional(:key).<predicate>(...)` rows.
# 3. Publish the resulting per-schema typed-key table as the `:dry_schema_table` ADR-9 cross-plugin fact.

require "spec_helper"

DRY_SCHEMA_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-dry-schema/lib", __dir__)
$LOAD_PATH.unshift(DRY_SCHEMA_PLUGIN_LIB) unless $LOAD_PATH.include?(DRY_SCHEMA_PLUGIN_LIB)
require "rigor-dry-schema"

DRY_TYPES_PLUGIN_LIB_FOR_SCHEMA = File.expand_path("../../../plugins/rigor-dry-types/lib", __dir__)
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
    # No `Types` module + no rigor-dry-types loaded → the constant reference doesn't resolve, key drops.
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

  # `each do ... end` element-type recursion — the ceiling slice issue #137 named for rigor-dry-schema.
  describe "`each do ... end` element-type recursion" do
    it "recurses a bare nested block into a nested required/optional shape" do
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:items).each do
            required(:sku).filled(:string)
            optional(:qty).value(:integer)
          end
        end
      RUBY
      shape = run_and_read_fact(demo: demo).fetch("Schema")
      row = shape.fetch(:required).fetch(:items)
      expect(row.fetch(:list)).to be(true)
      nested = row.fetch(:type).fetch(:nested)
      expect(nested.fetch(:required)).to eq(sku: { type: "String", list: false })
      expect(nested.fetch(:optional)).to eq(qty: { type: "Integer", list: false })
    end

    it "recurses the `each do schema do ... end end` spelling identically" do
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:items).each do
            schema do
              required(:sku).filled(:string)
            end
          end
        end
      RUBY
      shape = run_and_read_fact(demo: demo).fetch("Schema")
      nested = shape.fetch(:required).fetch(:items).fetch(:type).fetch(:nested)
      expect(nested.fetch(:required)).to eq(sku: { type: "String", list: false })
    end

    it "declines (untyped) a block with no recognisable required/optional row" do
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:known).filled(:string)
          required(:tags).each do
            int?
          end
        end
      RUBY
      shape = run_and_read_fact(demo: demo).fetch("Schema")
      expect(shape.fetch(:required)).to eq(known: { type: "String", list: false })
      expect(shape.fetch(:unmodelled)).to eq(required: [:tags], optional: [])
    end

    it "types `Schema.call(input).to_h` with a nested HashShape wrapped in Array" do
      dump = dump_types(<<~RUBY).first
        Schema = Dry::Schema.Params do
          required(:items).each do
            required(:sku).filled(:string)
          end
        end

        Rigor.dump_type(Schema.call({}).to_h)
      RUBY
      expect(dump).to include("items", "Array", "sku", "String")
    end

    it "resolves a nested row's constant type reference through :dry_type_aliases too" do
      demo = <<~RUBY
        module Types
          include Dry.Types()

          Email = String.constrained(format: /@/)
        end

        ContactBook = Dry::Schema.Params do
          required(:contacts).each do
            required(:email).value(Types::Email)
          end
        end
      RUBY
      shape = run_and_read_fact(demo: demo, with_dry_types: true).fetch("ContactBook")
      nested = shape.fetch(:required).fetch(:contacts).fetch(:type).fetch(:nested)
      expect(nested.fetch(:required)).to eq(email: { type: "String", list: false })
    end
  end

  # The `dry-schema.unknown-type` per-row diagnostic — the other ceiling slice issue #137 named.
  describe "`dry-schema.unknown-type` diagnostic" do
    it "fires :info for a type-bearing predicate's unrecognised Symbol argument" do
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:known).filled(:string)
          required(:bogus).filled(:not_a_type)
        end
      RUBY
      result = run_demo(demo)
      issue = result.diagnostics.find { |d| d.rule == "dry-schema.unknown-type" }
      expect(issue).not_to be_nil
      expect(issue.severity).to eq(:info)
      expect(issue.message).to include("bogus").or include(":not_a_type")
    end

    it "does NOT fire for a Constant argument even when rigor-dry-types isn't loaded" do
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:email).value(Types::Email)
        end
      RUBY
      result = run_demo(demo)
      expect(result.diagnostics.select { |d| d.rule == "dry-schema.unknown-type" }).to be_empty
    end

    it "does NOT fire for a recognised canonical type symbol" do
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:email).filled(:string)
          required(:age).value(:integer)
        end
      RUBY
      result = run_demo(demo)
      expect(result.diagnostics.select { |d| d.rule == "dry-schema.unknown-type" }).to be_empty
    end

    it "recurses into an `each do ... end` nested row's own bad symbol" do
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:items).each do
            required(:sku).filled(:not_a_type_either)
          end
        end
      RUBY
      result = run_demo(demo)
      issue = result.diagnostics.find { |d| d.rule == "dry-schema.unknown-type" }
      expect(issue).not_to be_nil
      expect(issue.message).to include("not_a_type_either")
    end
  end

  it "does NOT publish the fact when no `Dry::Schema.X` declaration is present" do
    demo = <<~RUBY
      class Foo
        def bar; "noop"; end
      end
    RUBY
    expect(run_and_read_fact(demo: demo)).to be_nil
  end

  # The typed `result.to_h` return — the first of the ceiling slices the plugin deferred to demand
  # (issue #137, README § "Floor / ceiling").
  describe "typed `SomeSchema.call(input).to_h`" do
    it "yields the schema's own hash shape instead of an untyped hash" do
      dump = dump_types(<<~RUBY).first
        NewUserSchema = Dry::Schema.Params do
          required(:email).filled(:string)
          required(:age).value(:integer)
        end

        Rigor.dump_type(NewUserSchema.call({}).to_h)
      RUBY
      expect(dump).to include("email", "String", "age", "Integer")
    end

    it "keeps an `optional` row's key optional and a `required` row's key required" do
      dump = dump_types(<<~RUBY).first
        Schema = Dry::Schema.Params do
          required(:email).filled(:string)
          optional(:nickname).maybe(:string)
        end

        Rigor.dump_type(Schema.call({}).to_h)
      RUBY
      # The declaration's own vocabulary carries over: `optional` reads as possibly-absent, `required`
      # does not. See ResultShape for why `to_h`'s worst case (a failed result drops required keys too)
      # is deliberately not modelled.
      expect(dump).to include("?nickname")
      expect(dump).not_to include("?email")
    end

    it "types an `each(<Type>)` row as an Array of that type" do
      dump = dump_types(<<~RUBY).first
        Schema = Dry::Schema.Params do
          required(:tags).each(:string)
        end

        Rigor.dump_type(Schema.call({}).to_h)
      RUBY
      expect(dump).to include("Array")
      expect(dump).to include("String")
    end

    it "widens a `:bool` row back to the two-class union the fact cannot carry" do
      # The published fact names one class per row, so `:bool` lands there as "TrueClass". A hash value
      # typed TrueClass would false-fire on every `false`.
      dump = dump_types(<<~RUBY).first
        Schema = Dry::Schema.Params do
          required(:admin).filled(:bool)
        end

        Rigor.dump_type(Schema.call({}).to_h)
      RUBY
      expect(dump).to include("FalseClass").or include("bool")
    end

    it "registers a schema declared under a namespace by its full constant path" do
      dump = dump_types(<<~RUBY).first
        module App
          module Schemas
            UserCreate = Dry::Schema.Params do
              required(:email).filled(:string)
            end
          end
        end

        Rigor.dump_type(App::Schemas::UserCreate.call({}).to_h)
      RUBY
      expect(dump).to include("email", "String")
    end

    it "contributes nothing to a `to_h` that is not a schema-result chain" do
      dumps = dump_types(<<~RUBY)
        Schema = Dry::Schema.Params do
          required(:email).filled(:string)
        end

        Rigor.dump_type(Schema.to_h)
        Rigor.dump_type(NotASchema.call({}).to_h)
        Rigor.dump_type({ a: 1 }.to_h)
      RUBY
      expect(dumps.size).to eq(3)
      expect(dumps).to all(satisfy { |message| !message.include?("email") })
    end

    it "keeps a declared key the scanner cannot type in the shape, as untyped" do
      # Asserted on the SHAPE, not on a read of it. Since #249 an undeclared key on an open shape already
      # reads as untyped, so `payload[:bogus]` infers the same whether or not the key is in the shape —
      # an assertion on the read would pass with this mechanism deleted. What it actually buys is that
      # the rendered shape still names the key, which is what hover shows.
      dumps = dump_types(<<~RUBY)
        Schema = Dry::Schema.Params do
          required(:email).filled(:string)
          required(:bogus).filled(:not_a_type)
          required(:address).schema do
            required(:city).filled(:string)
          end
        end

        payload = Schema.call({}).to_h
        Rigor.dump_type(payload)
        Rigor.dump_type(payload[:bogus])
      RUBY
      expect(dumps.first).to eq("dump_type: { email: String, bogus: Dynamic[top], address: Dynamic[top], ... }")
      expect(dumps.last).to eq("dump_type: Dynamic[top]")
    end

    it "contributes nothing for a schema that declares no key at all" do
      dumps = dump_types(<<~RUBY)
        Schema = Dry::Schema.Params do
          config.validate_keys = true
        end

        Rigor.dump_type(Schema.call({}).to_h)
      RUBY
      expect(dumps.first).not_to include("=>")
    end

    it "draws no diagnostic on a consumer that reads an undeclared key" do
      # The shape is open — dry-schema's key map only emits declared keys, but being wrong about that
      # would turn an ordinary read into a diagnostic, and this project weighs that cost higher.
      #
      # Scoped to the consumer lines: the declaration block itself draws an unrelated pre-existing
      # `required` diagnostic, because the fixture's RBS stub types the block parameter as untyped and
      # the DSL calls read as implicit-self calls on main.
      demo = <<~RUBY
        Schema = Dry::Schema.Params do
          required(:email).filled(:string)
        end

        payload = Schema.call({}).to_h
        payload[:email]
        payload[:undeclared]
      RUBY
      consumer_line = demo.lines.index { |line| line.start_with?("payload =") } + 1
      result = run_demo(demo)
      expect(result.diagnostics.select { |d| d.line >= consumer_line }).to be_empty
    end
  end

  # Runs the plugin against a single-file project and returns the `dump.type` messages, in source order.
  def dump_types(demo)
    run_demo(demo).diagnostics.select { |d| d.rule == "dump.type" }.map(&:message)
  end

  def run_demo(demo, with_dry_types: false)
    Rigor::Plugin.unregister!
    plugin_entries = with_dry_types ? %w[rigor-dry-types rigor-dry-schema] : ["rigor-dry-schema"]

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "schema.rb"), demo)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "dry_schema.rbs"), dry_schema_rbs)
      run_analysis(dir: dir, plugin_entries: plugin_entries)
    end
  end

  # Runs the plugin(s) against a single-file project and returns the `:dry_schema_table` fact value. Optionally
  # also loads rigor-dry-types (for the cross-plugin fact-resolution test).
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
      runner = Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: nil,
        plugin_requirer: lambda do |name|
          # #194 slice 2 — a bundled plugin now arrives as its engine-anchored absolute path; basename
          # recovers the gem name (a bare name passes through unchanged).
          case File.basename(name, ".rb")
          when "rigor-dry-types" then Rigor::Plugin.register(Rigor::Plugin::DryTypes)
          when "rigor-dry-schema" then Rigor::Plugin.register(Rigor::Plugin::DrySchema)
          end
          true
        end
      )
      guarded_run(runner)
    end
  end
end
