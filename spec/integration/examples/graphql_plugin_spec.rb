# frozen_string_literal: true

# Integration spec for `examples/rigor-graphql/`.
# Tier 3D per the Rails plugins roadmap.
#
# Slice 1 contract:
#
# 1. Walk the project for `class T < GraphQL::Schema::Object`
#    subclasses (including nested `module Types; class User < ...; end`).
# 2. Inside each, extract `field :name, Type, null: ...` declarations.
# 3. Publish the resulting `{type_class_fqn => {field_name => {type:, nullable:}}}`
#    table as the `:graphql_type_table` ADR-9 cross-plugin fact.

require "spec_helper"

GRAPHQL_PLUGIN_LIB = File.expand_path("../../../examples/rigor-graphql/lib", __dir__)
$LOAD_PATH.unshift(GRAPHQL_PLUGIN_LIB) unless $LOAD_PATH.include?(GRAPHQL_PLUGIN_LIB)
require "rigor-graphql"

RSpec.describe "rigor-graphql integration" do
  let(:plugin_class) { Rigor::Plugin::Graphql }

  let(:graphql_rbs) do
    <<~RBS
      module GraphQL
        module Schema
          class Object
            def self.field: (*untyped) { (?) -> void } -> void
                          | (*untyped) -> void
          end
        end
      end
    RBS
  end

  it "registers a manifest publishing :graphql_type_table + :graphql_enum_table" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("graphql")
    expect(manifest.produces).to include(:graphql_type_table, :graphql_enum_table)
  end

  describe "slice 2b — Schema::Enum recognition" do
    it "publishes the per-enum value list for a `Schema::Enum` subclass" do
      demo = <<~RUBY
        class Status < GraphQL::Schema::Enum
          value "ACTIVE"
          value "PENDING"
          value "DISABLED"
        end
      RUBY
      table = run_and_read_fact(demo: demo, fact_name: :graphql_enum_table)
      expect(table).not_to be_nil
      expect(table.fetch("Status")).to eq(%w[ACTIVE PENDING DISABLED])
    end

    it "registers nested enums under the enclosing constant chain" do
      demo = <<~RUBY
        module Types
          class Status < GraphQL::Schema::Enum
            value "OK"
            value "ERROR"
          end
        end
      RUBY
      table = run_and_read_fact(demo: demo, fact_name: :graphql_enum_table)
      expect(table).to have_key("Types::Status")
      expect(table.fetch("Types::Status")).to eq(%w[OK ERROR])
    end

    it "ignores `value` calls whose first arg isn't a literal String (slice 2b floor)" do
      demo = <<~RUBY
        class Status < GraphQL::Schema::Enum
          value "ACTIVE"
          value :SYMBOL_FORM
          value SOME_CONSTANT
        end
      RUBY
      values = run_and_read_fact(demo: demo, fact_name: :graphql_enum_table).fetch("Status")
      expect(values).to eq(%w[ACTIVE])
    end

    it "preserves additional kwargs (`value:`, `description:`) without dropping the row" do
      demo = <<~RUBY
        class Status < GraphQL::Schema::Enum
          value "ACTIVE", description: "currently in use"
          value "DISABLED", value: :off
        end
      RUBY
      values = run_and_read_fact(demo: demo, fact_name: :graphql_enum_table).fetch("Status")
      expect(values).to eq(%w[ACTIVE DISABLED])
    end

    it "publishes both facts when a project mixes Schema::Object and Schema::Enum" do
      demo = <<~RUBY
        class User < GraphQL::Schema::Object
          field :name, String, null: false
        end

        class Status < GraphQL::Schema::Enum
          value "ACTIVE"
        end
      RUBY
      types = run_and_read_fact(demo: demo, fact_name: :graphql_type_table)
      enums = run_and_read_fact(demo: demo, fact_name: :graphql_enum_table)
      expect(types).to have_key("User")
      expect(enums).to have_key("Status")
    end

    it "does NOT publish :graphql_enum_table when no Schema::Enum subclass is present" do
      demo = <<~RUBY
        class User < GraphQL::Schema::Object
          field :name, String, null: false
        end
      RUBY
      expect(run_and_read_fact(demo: demo, fact_name: :graphql_enum_table)).to be_nil
    end
  end

  it "publishes the per-type field map for a `Schema::Object` subclass" do
    demo = <<~RUBY
      class User < GraphQL::Schema::Object
        field :name, String, null: false
        field :email, String, null: true
        field :age, Integer, null: false
        field :is_active, Boolean, null: false
        field :rating, Float, null: false
        field :uid, ID, null: false
      end
    RUBY
    table = run_and_read_fact(demo: demo)
    expect(table).not_to be_nil
    expect(table.fetch("User")).to eq(
      "name" => { type: "String", nullable: false, list: false },
      "email" => { type: "String", nullable: true, list: false },
      "age" => { type: "Integer", nullable: false, list: false },
      "is_active" => { type: "TrueClass", nullable: false, list: false },
      "rating" => { type: "Float", nullable: false, list: false },
      "uid" => { type: "String", nullable: false, list: false }
    )
  end

  it "registers nested types under the enclosing constant chain" do
    demo = <<~RUBY
      module Types
        class User < GraphQL::Schema::Object
          field :name, String, null: false
        end
      end
    RUBY
    table = run_and_read_fact(demo: demo)
    expect(table).to have_key("Types::User")
    expect(table.fetch("Types::User")).to eq(
      "name" => { type: "String", nullable: false, list: false }
    )
  end

  it "preserves user-defined types as their qualified name (downstream consumers resolve)" do
    demo = <<~RUBY
      class Post < GraphQL::Schema::Object
        field :author, Types::User, null: false
        field :status, Types::Status, null: true
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("Post")
    expect(fields).to eq(
      "author" => { type: "Types::User", nullable: false, list: false },
      "status" => { type: "Types::Status", nullable: true, list: false }
    )
  end

  it "defaults nullability to true when `null:` is omitted (graphql-ruby default)" do
    demo = <<~RUBY
      class User < GraphQL::Schema::Object
        field :nickname, String
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("User")
    expect(fields.fetch("nickname")).to eq(type: "String", nullable: true, list: false)
  end

  it "recognises list-wrapped scalar types (`[String]`) as list-of-element" do
    demo = <<~RUBY
      class Post < GraphQL::Schema::Object
        field :tags, [String], null: false
        field :scores, [Integer], null: true
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("Post")
    expect(fields).to eq(
      "tags" => { type: "String", nullable: false, list: true },
      "scores" => { type: "Integer", nullable: true, list: true }
    )
  end

  it "recognises list-wrapped user-defined types (`[Types::Author]`)" do
    demo = <<~RUBY
      class Post < GraphQL::Schema::Object
        field :authors, [Types::Author], null: false
        field :revisions, [Types::Revision], null: true
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("Post")
    expect(fields).to eq(
      "authors" => { type: "Types::Author", nullable: false, list: true },
      "revisions" => { type: "Types::Revision", nullable: true, list: true }
    )
  end

  it "ignores multi-element / empty list literals (not GraphQL list shape)" do
    demo = <<~RUBY
      class Bad < GraphQL::Schema::Object
        field :empty, [], null: false
        field :multi, [String, Integer], null: false
        field :real, String, null: false
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("Bad")
    expect(fields.keys).to contain_exactly("real")
  end

  it "ignores `field` calls whose first arg isn't a literal Symbol (defensive)" do
    demo = <<~RUBY
      class User < GraphQL::Schema::Object
        field "string_key", String, null: false
        field :real, String, null: false
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("User")
    expect(fields.keys).to contain_exactly("real")
  end

  it "ignores `field` calls without a constant type argument (string-form deferred)" do
    demo = <<~RUBY
      class User < GraphQL::Schema::Object
        field :name, "User", null: false
        field :real, String, null: false
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("User")
    expect(fields.keys).to contain_exactly("real")
  end

  it "recognises lexically-nested `< Schema::Object` (inside `module GraphQL`)" do
    demo = <<~RUBY
      module GraphQL
        class Widget < Schema::Object
          field :label, String, null: false
        end
      end
    RUBY
    expect(run_and_read_fact(demo: demo)).to have_key("GraphQL::Widget")
  end

  it "does NOT publish the fact when no `Schema::Object` subclass is present" do
    demo = <<~RUBY
      class Foo
        def bar; "noop"; end
      end
    RUBY
    expect(run_and_read_fact(demo: demo)).to be_nil
  end

  it "ignores subclasses of unrelated parents named `Object`" do
    demo = <<~RUBY
      class Bag < Container::Object
        field :name, String, null: false
      end
    RUBY
    # `Container::Object` has the right tail name but wrong
    # parent — must not register as a GraphQL type.
    expect(run_and_read_fact(demo: demo)).to be_nil
  end

  def run_and_read_fact(demo:, fact_name: :graphql_type_table)
    Rigor::Plugin.unregister!
    captured_store = nil
    allow(Rigor::Plugin::Services).to receive(:new).and_wrap_original do |original, **kwargs|
      services = original.call(**kwargs)
      captured_store = services.fact_store
      services
    end

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "types.rb"), demo)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "graphql.rbs"), graphql_rbs)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "types.rb")],
          "plugins" => ["rigor-graphql"]
        )
      )

      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        ).run
      end
    end
    captured_store&.read(plugin_id: "graphql", name: fact_name)
  end
end
