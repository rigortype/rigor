# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Base do
  let(:services) do
    Rigor::Plugin::Services.new(
      reflection: Rigor::Reflection,
      type: Rigor::Type::Combinator,
      configuration: Rigor::Configuration.new
    )
  end

  describe ".manifest" do
    it "stores a manifest declared at class definition" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "1.2.3", description: "demo plugin")
      end

      expect(klass.manifest).to be_a(Rigor::Plugin::Manifest)
      expect(klass.manifest.id).to eq("demo")
      expect(klass.manifest.description).to eq("demo plugin")
    end

    it "raises when accessed without a prior declaration" do
      klass = Class.new(described_class)
      expect { klass.manifest }.to raise_error(ArgumentError, /did not declare a manifest/)
    end
  end

  describe "#initialize" do
    it "stores the injected services and frozen config" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end

      plugin = klass.new(services: services, config: { "k" => 1 })
      expect(plugin.services).to eq(services)
      expect(plugin.config).to eq({ "k" => 1 })
      expect(plugin.config).to be_frozen
    end

    it "delegates `manifest` to the class" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      plugin = klass.new(services: services)
      expect(plugin.manifest).to eq(klass.manifest)
    end
  end

  describe "#init" do
    it "is a no-op by default" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")
      end
      plugin = klass.new(services: services)
      expect(plugin.init(services)).to be_nil
    end

    it "can be overridden by subclasses" do
      klass = Class.new(described_class) do
        manifest(id: "demo", version: "0.1.0")

        attr_reader :captured

        def init(services)
          @captured = services.reflection
        end
      end

      plugin = klass.new(services: services)
      plugin.init(services)
      expect(plugin.captured).to eq(Rigor::Reflection)
    end
  end

  describe "#glob_descriptor" do
    let(:plugin_class) do
      Class.new(described_class) do
        manifest(id: "glob-demo", version: "0.1.0")
      end
    end

    let(:plugin) { plugin_class.new(services: services) }

    it "returns FileEntry rows with :digest comparator for every matching file" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "a.rb"), "puts :a\n")
        File.write(File.join(dir, "lib", "b.rb"), "puts :b\n")
        File.write(File.join(dir, "lib", "ignored.txt"), "not ruby\n")

        descriptor = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        paths = descriptor.files.map(&:path).map { |p| File.basename(p) }
        expect(paths).to contain_exactly("a.rb", "b.rb")
        expect(descriptor.files.map(&:comparator).uniq).to eq([:digest])
      end
    end

    it "returns content-keyed entries so the cache key differs across content changes" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        path = File.join(dir, "lib", "x.rb")

        File.write(path, "puts :first\n")
        before = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        File.write(path, "puts :second\n")
        after = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        expect(before).not_to eq(after)
      end
    end

    it "differs when files are added or removed from the matched glob" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "a.rb"), "puts :a\n")

        before = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        File.write(File.join(dir, "lib", "b.rb"), "puts :b\n")
        after = plugin.glob_descriptor([File.join(dir, "lib")], "**/*.rb")

        expect(before).not_to eq(after)
      end
    end

    it "returns an empty descriptor when no roots exist on disk" do
      descriptor = plugin.glob_descriptor(["/definitely/does/not/exist"], "**/*.rb")
      expect(descriptor.files).to be_empty
    end

    it "unions multiple glob patterns under each root" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        File.write(File.join(dir, "a.rb"), "")
        File.write(File.join(dir, "b.erb"), "")
        File.write(File.join(dir, "c.txt"), "")

        descriptor = plugin.glob_descriptor([dir], "**/*.rb", "**/*.erb")
        names = descriptor.files.map(&:path).map { |p| File.basename(p) }
        expect(names).to contain_exactly("a.rb", "b.erb")
      end
    end

    it "skips directories (FileEntry needs file content)" do
      Dir.mktmpdir("rigor-glob-desc-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "sub"))
        File.write(File.join(dir, "a.rb"), "")
        # `**/*` matches both `sub` and `a.rb`; only `a.rb` should
        # appear in the descriptor.
        descriptor = plugin.glob_descriptor([dir], "**/*")
        names = descriptor.files.map(&:path).map { |p| File.basename(p) }
        expect(names).to contain_exactly("a.rb")
      end
    end
  end
end
