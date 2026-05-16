# frozen_string_literal: true

# Integration spec for `examples/rigor-dry-struct/`. ADR-16 slice 2c.
# Exercises the substrate's Tier C path end-to-end:
#
# 1. Load the example plugin via the `rigor-dry-struct` entry point.
# 2. Run rigor against a multi-file Dry::Struct fixture with a
#    minimal Dry::Struct RBS stub.
# 3. Assert that cross-file dispatch through the synthesised
#    readers resolves (no `call.undefined-method` for
#    `address.city` / `user.name` etc.).
#
# Per WD13 floor — the synthetic readers return `Dynamic[T]`;
# this spec verifies the *name resolution* path, not precise
# return typing (which is the slice-6 ceiling).

require "spec_helper"

DRY_STRUCT_PLUGIN_LIB = File.expand_path("../../../examples/rigor-dry-struct/lib", __dir__)
$LOAD_PATH.unshift(DRY_STRUCT_PLUGIN_LIB) unless $LOAD_PATH.include?(DRY_STRUCT_PLUGIN_LIB)
require "rigor-dry-struct"

RSpec.describe "rigor-dry-struct integration" do
  let(:plugin_class) { Rigor::Plugin::DryStruct }

  let(:dry_struct_rbs) do
    <<~RBS
      module Dry
        class Struct
          def self.attribute: (Symbol, untyped) -> void
          def self.attribute?: (Symbol, untyped) -> void
          def to_h: () -> Hash[Symbol, untyped]
          def []: (Symbol) -> untyped
        end
      end

      module Types
        String: untyped
        Bool: untyped
      end
    RBS
  end

  let(:demo_source) do
    <<~RUBY
      class Address < Dry::Struct
        attribute :city, Types::String
        attribute :country, Types::String
        attribute? :postcode, Types::String
      end

      class User < Dry::Struct
        attribute :name, Types::String
        attribute :admin, Types::Bool
      end
    RUBY
  end

  let(:consumer_source) do
    <<~RUBY
      def greet_address(address)
        "\#{address.city}, \#{address.country}"
      end

      def admin_summary(user)
        return "regular: \#{user.name}" unless user.admin

        "admin: \#{user.name}"
      end
    RUBY
  end

  it "registers a manifest with two Tier C heredoc_templates (attribute / attribute?)" do
    manifest = plugin_class.manifest
    expect(manifest.id).to eq("dry-struct")
    expect(manifest.heredoc_templates.size).to eq(2)
    method_names = manifest.heredoc_templates.map(&:method_name)
    expect(method_names).to eq(%i[attribute attribute?])
    manifest.heredoc_templates.each do |template|
      expect(template.receiver_constraint).to eq("Dry::Struct")
      expect(template.emit.size).to eq(1)
      expect(template.emit.first.name).to eq("\#{name}")
    end
  end

  it "synthesises cross-file readers so attribute calls resolve through the substrate" do
    result = run_under_plugin(demo: demo_source, consumer: consumer_source)
    undefined = result.diagnostics.select do |d|
      d.rule.to_s.include?("undefined-method") &&
        %w[city country name admin].any? { |reader| d.message.include?(reader) }
    end
    expect(undefined).to(
      be_empty,
      "expected Dry::Struct attribute readers to resolve cross-file via the substrate; " \
      "got: #{undefined.map(&:message).inspect}"
    )
  end

  describe "ADR-18 precision uplift via rigor-dry-types fact (slice 5)" do
    before(:all) do # rubocop:disable RSpec/BeforeAfterAll
      dry_types_plugin_lib = File.expand_path("../../../examples/rigor-dry-types/lib", __dir__)
      $LOAD_PATH.unshift(dry_types_plugin_lib) unless $LOAD_PATH.include?(dry_types_plugin_lib)
      require "rigor-dry-types"
    end

    let(:dry_types_plugin) { Rigor::Plugin::DryTypes }

    let(:types_module) do
      <<~RUBY
        module Types
          include Dry.Types()
        end
      RUBY
    end

    it "promotes the synthesised reader's return type via :dry_type_aliases" do # rubocop:disable RSpec/ExampleLength
      Rigor::Plugin.unregister!
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "types.rb"), types_module)
        File.write(File.join(dir, "demo.rb"), demo_source)
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig", "dry_struct.rbs"), dry_struct_rbs)
        File.write(File.join(dir, "sig", "dry_types.rbs"), <<~RBS)
          module Dry
            def self.Types: () -> Module
          end
        RBS

        # Capture the synthesised methods directly so we can
        # assert on their `return_type` instead of relying on
        # downstream call-site narrowing (which would need
        # `Types::String` to resolve at the constant-typing
        # tier — separate work).
        captured_index = nil
        allow(Rigor::Inference::SyntheticMethodIndex).to receive(:new).and_wrap_original do |original, **kwargs|
          captured_index = original.call(**kwargs)
          captured_index
        end

        configuration = Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => [File.join(dir, "demo.rb"), File.join(dir, "types.rb")],
            "plugins" => %w[rigor-dry-types rigor-dry-struct]
          )
        )

        Dir.chdir(dir) do
          Rigor::Analysis::Runner.new(
            configuration: configuration,
            cache_store: nil,
            plugin_requirer: lambda do |name|
              case name
              when "rigor-dry-types" then Rigor::Plugin.register(dry_types_plugin)
              when "rigor-dry-struct" then Rigor::Plugin.register(plugin_class)
              end
              true
            end
          ).run
        end

        expect(captured_index).not_to be_nil
        city = captured_index.lookup_instance("Address", :city)
        expect(city).not_to be_empty
        expect(city.first.return_type).to eq("String")
      end
    end
  end

  def run_under_plugin(demo:, consumer:)
    Rigor::Plugin.unregister!
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), demo)
      File.write(File.join(dir, "consumer.rb"), consumer)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "dry_struct.rbs"), dry_struct_rbs)

      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb"), File.join(dir, "consumer.rb")],
          "plugins" => ["rigor-dry-struct"]
        )
      )

      Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration,
          cache_store: nil,
          plugin_requirer: lambda do |_name|
            Rigor::Plugin.register(plugin_class)
            true
          end
        ).run
      end
    end
  end
end
