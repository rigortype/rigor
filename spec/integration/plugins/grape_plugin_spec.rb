# frozen_string_literal: true

# Integration spec for `plugins/rigor-grape/` (issue #1099).
#
# Contract:
#
# 1. `class API < Grape::API` bodies type the class-level declaration DSL (`params`, `namespace`,
#    the HTTP verb macros, `desc`, `route_setting`, `helpers`, …) against the bundled sig instead of
#    going `Dynamic[top]`.
# 2. `block_as_methods` narrows block `self` the way Grape `instance_eval`s them: `params` bodies on
#    `Grape::Validations::ParamsScope`, `namespace` bodies on the `Grape::API::Instance` class object,
#    verb bodies on `Grape::Endpoint` — so `requires`/`optional` inside `params`, nested `namespace`,
#    and `error!`/`present`/`params` inside `get` all resolve.
# 3. `class E < Grape::Entity` bodies type `expose`/`documentation`/`format_with` via the
#    `rbs_complete_ancestors` bridge; nested `expose` bodies (`block.call`, self unchanged) resolve
#    through the same singleton surface.
# 4. Unrelated classes keep the Dynamic fallback (false-positive discipline).

GRAPE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-grape/lib", __dir__)
$LOAD_PATH.unshift(GRAPE_PLUGIN_LIB) unless $LOAD_PATH.include?(GRAPE_PLUGIN_LIB)
require "rigor-grape"

RSpec.describe "rigor-grape integration" do
  let(:plugin_class) { Rigor::Plugin::Grape }

  it "registers a manifest targeting grape + grape-entity" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("grape")
    expect(manifest.target_gems).to eq(%w[grape grape-entity])
    expect(manifest.rbs_complete_ancestors).to include("Grape::API", "Grape::Entity")
    expect(manifest.open_receivers).to include(
      "Grape::API", "Grape::API::Instance", "Grape::Entity",
      "Grape::Validations::ParamsScope", "Grape::Endpoint"
    )
  end

  def dump_types(source)
    result = run_plugin(source: source)
    result.diagnostics
          .select { |d| d.qualified_rule == "dump.type" }
          .map { |d| d.message.sub("dump_type: ", "") }
  end

  def run_plugin(source:)
    Rigor::Plugin.unregister!
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "plugins" => ["rigor-grape"],
        "bundler" => { "auto_detect" => false },
        "rbs_collection" => { "auto_detect" => false }
      )
    )
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration, cache_store: nil,
      plugin_requirer: lambda { |_name|
        Rigor::Plugin.register(plugin_class)
        true
      }
    )
    guarded_run_source(runner, source: source)
  end

  it "types the class-body declaration DSL on a Grape::API subclass" do
    source = <<~RUBY
      class API < Grape::API
        Rigor.dump_type(desc "list things")
        Rigor.dump_type(route_setting :swagger, tags: %w[things])
        Rigor.dump_type(helpers SharedHelpers)
        Rigor.dump_type(use Rack::JSONP)
        Rigor.dump_type(mount V1::Things)
        Rigor.dump_type(params do; end)
        Rigor.dump_type(get "/things" do; end)
      end
    RUBY
    expect(dump_types(source)).to eq(
      ["Object?", "Object?", "Object?", "Object?", "Object?",
       "Grape::Validations::ParamsScope", "Object?"]
    )
  end

  it "bridges a root-prefixed intermediate base class and DSL calls inside iterator blocks" do
    # The gitlab shape: `class AccessRequests < ::API::Base` where `API::Base < Grape::API`, with
    # declaration calls nested in `%w[...].each do` bodies (self stays the class object).
    source = <<~RUBY
      module API
        class Base < ::Grape::API
        end

        class AccessRequests < ::API::Base
          %w[group project].each do |source_type|
            Rigor.dump_type(desc "list \#{source_type}")
            params do
              Rigor.dump_type(requires :id, type: String)
            end
            namespace :things do
              Rigor.dump_type(route_setting :swagger, tags: %w[things])
            end
          end
        end
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Object? Object? Object?])
  end

  it "binds `params` block self to ParamsScope so requires/optional/grouping macros resolve" do
    source = <<~RUBY
      class API < Grape::API
        params do
          Rigor.dump_type(requires :id, type: Integer)
          Rigor.dump_type(optional :q, type: String)
          Rigor.dump_type(mutually_exclusive :a, :b)
          Rigor.dump_type(use :pagination)
        end
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Object? Object? Object? Object?])
  end

  it "re-enters ParamsScope for nested `requires ... do` bodies" do
    source = <<~RUBY
      class API < Grape::API
        params do
          requires :user, type: Hash do
            Rigor.dump_type(requires :name, type: String)
            Rigor.dump_type(optional :age, type: Integer)
          end
        end
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Object? Object?])
  end

  it "binds `namespace` block self to the Instance class object so nested DSL resolves" do
    source = <<~RUBY
      class API < Grape::API
        namespace :things do
          Rigor.dump_type(route_setting :swagger, hidden: true)
          Rigor.dump_type(desc "a namespaced route")
          params do
            Rigor.dump_type(requires :id)
          end
          namespace :nested do
            Rigor.dump_type(get "/deep" do; end)
          end
        end
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Object? Object? Object? Object?])
  end

  # `scope` routes through `within_namespace { nest(block) }` (dsl/routing.rb) — the block
  # `instance_eval`s on the Instance class object like `namespace`, so it must be in
  # NAMESPACE_METHODS (Codex adversarial review, grape 2.4.0).
  it "binds `scope` block self to the Instance class object like `namespace`" do
    source = <<~RUBY
      class API < Grape::API
        scope do
          Rigor.dump_type(route_setting :swagger, hidden: true)
          params do
            Rigor.dump_type(optional :id)
          end
        end
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Object? Object?])
  end

  # `desc 'x' do ... end` `instance_exec`s on a generated SettingsContainer subclass
  # (StrictHashConfiguration.config_class(*Desc::ROUTE_ATTRIBUTES) via desc_container) — the
  # dominant gitlab `lib/api` desc-block idiom (`detail`/`success`/`failure`/`tags`).
  it "binds `desc` block self to the route-attribute config context" do
    source = <<~RUBY
      class API < Grape::API
        desc 'Create a thing' do
          Rigor.dump_type(detail 'This feature was introduced in 1.0')
          Rigor.dump_type(success Entities::Thing)
          Rigor.dump_type(success code: 200, model: Entities::Thing)
          Rigor.dump_type(failure [{ code: 400 }])
          Rigor.dump_type(tags %w[things])
          Rigor.dump_type(entity Entities::Thing)
          Rigor.dump_type(hidden true)
        end
        namespace :things do
          desc 'List things' do
            Rigor.dump_type(is_array true)
          end
        end
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Object? Object? Object? Object? Object? Object? Object? Object?])
  end

  it "types `Endpoint#cookies` as Grape::Cookies, not Hash" do
    source = <<~RUBY
      class API < Grape::API
        get "/things" do
          Rigor.dump_type(cookies)
        end
      end
    RUBY
    expect(dump_types(source)).to eq(["Grape::Cookies"])
  end

  it "types `Entity.root_exposures` as NestedExposures, not Array" do
    source = <<~RUBY
      class ThingEntity < Grape::Entity
        Rigor.dump_type(root_exposures)
      end
    RUBY
    expect(dump_types(source)).to eq(["Grape::Entity::Exposure::NestingExposure::NestedExposures"])
  end

  it "binds verb block self to Grape::Endpoint so inside-route calls resolve" do
    source = <<~RUBY
      class API < Grape::API
        get "/things/:id" do
          Rigor.dump_type(params)
          Rigor.dump_type(declared(params))
          Rigor.dump_type(present Thing, with: Entities::Thing)
          Rigor.dump_type(error! "nope", 404)
        end
      end
    RUBY
    expect(dump_types(source)).to eq(
      ["Hash[Dynamic[top], Dynamic[top]]", "Hash[Dynamic[top], Dynamic[top]]", "Dynamic[top]", "bot"]
    )
  end

  it "types `version`/`route_param`/`given` bodies as Instance class-object evaluation" do
    source = <<~RUBY
      class API < Grape::API
        version "v1" do
          Rigor.dump_type(desc "v1 routes")
        end
        route_param :tenant do
          Rigor.dump_type(get "/" do; end)
        end
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Object? Object?])
  end

  it "types the Grape::Entity exposure DSL, including nested `expose` bodies" do
    source = <<~RUBY
      class ThingEntity < Grape::Entity
        Rigor.dump_type(expose :id, documentation: { type: Integer })
        Rigor.dump_type(documentation)
        Rigor.dump_type(format_with(:timestamp) { |d| d.to_s })
        expose :nested do
          Rigor.dump_type(expose :inner)
        end
      end
    RUBY
    expect(dump_types(source)).to eq(
      ["Array[Dynamic[top]]", "Hash[Dynamic[top], Dynamic[top]]", "Proc", "Array[Dynamic[top]]"]
    )
  end

  it "keeps DSL-looking calls on unrelated classes Dynamic" do
    source = <<~RUBY
      class NotAnAPI
        Rigor.dump_type(params do; end)
        Rigor.dump_type(get "/x" do; end)
      end
      class NotAnEntity
        Rigor.dump_type(expose :id)
      end
    RUBY
    expect(dump_types(source)).to eq(%w[Dynamic[top] Dynamic[top] Dynamic[top]])
  end
end
