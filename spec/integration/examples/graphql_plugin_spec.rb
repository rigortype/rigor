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

  it "registers a manifest publishing :graphql_type_table" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("graphql")
    expect(manifest.produces).to include(:graphql_type_table)
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
      "name" => { type: "String", nullable: false },
      "email" => { type: "String", nullable: true },
      "age" => { type: "Integer", nullable: false },
      "is_active" => { type: "TrueClass", nullable: false },
      "rating" => { type: "Float", nullable: false },
      "uid" => { type: "String", nullable: false }
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
      "name" => { type: "String", nullable: false }
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
      "author" => { type: "Types::User", nullable: false },
      "status" => { type: "Types::Status", nullable: true }
    )
  end

  it "defaults nullability to true when `null:` is omitted (graphql-ruby default)" do
    demo = <<~RUBY
      class User < GraphQL::Schema::Object
        field :nickname, String
      end
    RUBY
    fields = run_and_read_fact(demo: demo).fetch("User")
    expect(fields.fetch("nickname")).to eq(type: "String", nullable: true)
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

  def run_and_read_fact(demo:)
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
    captured_store&.read(plugin_id: "graphql", name: :graphql_type_table)
  end
end
