# frozen_string_literal: true

require "spec_helper"
require "tempfile"

require "rigor/inference/synthetic_method_scanner"
require "rigor/plugin"

RSpec.describe Rigor::Inference::SyntheticMethodScanner do
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  let(:dry_struct_plugin) do
    Class.new(Rigor::Plugin::Base) do
      manifest(
        id: "drystructfixture",
        version: "0.1.0",
        heredoc_templates: [
          Rigor::Plugin::Macro::HeredocTemplate.new(
            receiver_constraint: "Dry::Struct",
            method_name: :attribute,
            symbol_arg_position: 0,
            emit: [{ name: "\#{name}", returns: "Object" }]
          )
        ]
      )
    end
  end

  def write_files(files)
    dir = Dir.mktmpdir("rigor-scanner-spec-")
    files.each do |relpath, body|
      full = File.join(dir, relpath)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end
    paths = files.keys.map { |rel| File.join(dir, rel) }
    [dir, paths]
  end

  def stub_environment_for(hierarchy: { "Address" => "Dry::Struct" })
    env = instance_double(Rigor::Environment)
    allow(env).to receive(:class_ordering) do |lhs, rhs|
      if lhs == rhs
        :equal
      elsif hierarchy[lhs] == rhs
        :subclass
      else
        :unrelated
      end
    end
    env
  end

  describe ".scan" do
    it "returns SyntheticMethodIndex::EMPTY when no plugin contributes heredoc_templates" do
      registry = Rigor::Plugin::Registry.new(plugins: [])
      _, paths = write_files("demo.rb" => "class Address < Dry::Struct\nend\n")
      index = described_class.scan(plugin_registry: registry, paths: paths)
      expect(index).to be(Rigor::Inference::SyntheticMethodIndex::EMPTY)
    end

    it "emits a SyntheticMethod for each literal attribute :name argument" do
      registry = Rigor::Plugin::Registry.new(plugins: [dry_struct_plugin.new(services: services)])
      _, paths = write_files(
        "address.rb" => <<~RUBY
          class Address < Dry::Struct
            attribute :city, Types::String
            attribute :country, Types::String
          end
        RUBY
      )
      index = described_class.scan(plugin_registry: registry, paths: paths, environment: stub_environment_for)
      city = index.lookup_instance("Address", :city)
      country = index.lookup_instance("Address", :country)
      expect(city.size).to eq(1)
      expect(country.size).to eq(1)
      expect(city.first.return_type).to eq("Object")
      expect(city.first.provenance[:plugin_id]).to eq("drystructfixture")
    end

    it "matches lexical inheritance chains across files" do
      registry = Rigor::Plugin::Registry.new(plugins: [dry_struct_plugin.new(services: services)])
      _, paths = write_files(
        "base.rb" => "class AppStruct < Dry::Struct\nend\n",
        "address.rb" => <<~RUBY
          class Address < AppStruct
            attribute :city, Types::String
          end
        RUBY
      )
      index = described_class.scan(plugin_registry: registry, paths: paths, environment: stub_environment_for)
      expect(index.lookup_instance("Address", :city).size).to eq(1)
    end

    it "skips attribute calls with non-literal first argument" do
      registry = Rigor::Plugin::Registry.new(plugins: [dry_struct_plugin.new(services: services)])
      _, paths = write_files(
        "address.rb" => <<~RUBY
          class Address < Dry::Struct
            attribute some_dynamic_name, Types::String
          end
        RUBY
      )
      index = described_class.scan(plugin_registry: registry, paths: paths, environment: stub_environment_for)
      expect(index).to be_empty
    end

    it "skips classes that do not inherit the receiver_constraint" do
      registry = Rigor::Plugin::Registry.new(plugins: [dry_struct_plugin.new(services: services)])
      _, paths = write_files(
        "user.rb" => <<~RUBY
          class User
            attribute :city, Types::String
          end
        RUBY
      )
      index = described_class.scan(plugin_registry: registry, paths: paths, environment: stub_environment_for)
      expect(index).to be_empty
    end

    it "tolerates missing files / parse errors silently" do
      registry = Rigor::Plugin::Registry.new(plugins: [dry_struct_plugin.new(services: services)])
      _, paths = write_files("ok.rb" => "class Address < Dry::Struct; attribute :city, T; end\n")
      paths << "/no/such/file.rb"
      index = described_class.scan(plugin_registry: registry, paths: paths, environment: stub_environment_for)
      expect(index.lookup_instance("Address", :city).size).to eq(1)
    end

    it "emits class_level_emit rows as singleton synthetic methods" do
      with_class_emit_plugin = Class.new(Rigor::Plugin::Base) do
        manifest(
          id: "withclassemit",
          version: "0.1.0",
          heredoc_templates: [
            Rigor::Plugin::Macro::HeredocTemplate.new(
              receiver_constraint: "Dry::Struct",
              method_name: :attribute,
              emit: [{ name: "\#{name}", returns: "Object" }],
              class_level_emit: [{ name: "find_by_\#{name}", returns: "Object" }]
            )
          ]
        )
      end
      registry = Rigor::Plugin::Registry.new(plugins: [with_class_emit_plugin.new(services: services)])
      _, paths = write_files(
        "address.rb" => "class Address < Dry::Struct; attribute :city, T; end\n"
      )
      index = described_class.scan(plugin_registry: registry, paths: paths, environment: stub_environment_for)
      expect(index.lookup_instance("Address", :city).size).to eq(1)
      expect(index.lookup_singleton("Address", :find_by_city).size).to eq(1)
    end
  end
end
