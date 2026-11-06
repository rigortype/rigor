# frozen_string_literal: true

require "rigor/lens/claims/type_reader"
require "rigor/lens"
require "tmpdir"

RSpec.describe Rigor::Lens::Claims::TypeReader do
  def read_claim(source, nesting:, claim: "String", files: {})
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        File.write("claim.rb", source)
        files.each { |path, contents| File.write(path, contents) }
        configuration = Rigor::Configuration.new("paths" => ["."], "plugins" => [], "signature_paths" => [])
        run = Rigor::Lens::Run.new(configuration: configuration, root: Dir.pwd, arguments: ["claim.rb"], workers: 0)
        expect(run.call.targets.first.status).to eq("ok")
        reader = described_class.new(scope: run.claim_contexts.fetch(File.expand_path("claim.rb")), nesting: nesting)
        reader.read(RBS::Parser.parse_type(claim), claim: true)
        reader
      end
    end
  end

  it "resolves core names when the project has no shadow" do
    reader = read_claim("class API; end", nesting: ["API"])

    expect(reader.reasons).to be_empty
  end

  it "finds a project constant in a prepended module" do
    reader = read_claim(<<~RUBY, nesting: ["API"])
      module Shadow
        class String; end
      end
      class API
        prepend Shadow
      end
    RUBY

    expect(reader.reasons).to include("ambiguous_name")
  end

  it "resolves a superclass spelling in its recorded lexical namespace" do
    reader = read_claim(<<~RUBY, nesting: %w[Space Space::API])
      module Space
        class Parent
          class String; end
        end
        class API < Parent; end
      end
    RUBY

    expect(reader.reasons).to include("ambiguous_name")
  end

  it "keeps a written value constant ahead of the RBS core name" do
    reader = read_claim(<<~RUBY, nesting: ["API"])
      class API
        String = Object
      end
    RUBY

    expect(reader.reasons).to include("ambiguous_name")
  end

  it "finds an ancestor shadow in a seeded file that was not requested" do
    reader = read_claim("class API < Parent; end", nesting: ["API"],
                                                   files: { "parent.rb" => "class Parent; class String; end; end" })

    expect(reader.reasons).to include("ambiguous_name")
  end

  it "declines an ancestry with an unnameable mixin" do
    reader = read_claim(<<~RUBY, nesting: ["API"])
      class API
        include choose_module
      end
    RUBY

    expect(reader.reasons).to include("ambiguous_name")
  end

  it "does not let uncertain ancestry override a lexical constant" do
    reader = read_claim(<<~RUBY, nesting: ["Process"], claim: "Status")
      module Process
        class Status; end
        include choose_module
      end
    RUBY

    expect(reader.reasons).to be_empty
  end

  it "leaves absolute names independent of project ancestry" do
    reader = read_claim(<<~RUBY, nesting: ["API"], claim: "::String")
      class API
        include choose_module
      end
    RUBY

    expect(reader.reasons).to be_empty
  end

  it "does not build a resolver when the RBS environment is unavailable" do
    loader = Rigor::Environment::RbsLoader.new
    allow(loader).to receive(:env).and_return(nil)

    expect(loader.type_name_resolver).to be_nil
    scope = Rigor::Scope.empty(environment: Rigor::Environment.new(rbs_loader: loader))
    reader = described_class.new(scope: scope, nesting: [])
    expect(reader.read(RBS::Parser.parse_type("String"), claim: true)).to be_empty
    expect(reader.reasons).to include("unresolved_name")
  end

  it "constructs an independent resolver on RBS versions without the build factory" do
    loader = Rigor::Environment::RbsLoader.new
    environment = Object.new
    allow(loader).to receive(:env).and_return(environment)
    resolver_class = Class.new do
      attr_reader :environment

      def initialize(environment)
        @environment = environment
      end
    end
    stub_const("RBS::Resolver::TypeNameResolver", resolver_class)

    first = loader.type_name_resolver
    expect(first.environment).to equal(environment)
    expect(loader.type_name_resolver).not_to equal(first)
  end

  it "reads an empty, blank or comment-only claim as a syntax error" do
    ["", "  ", "#x"].each do |text|
      expect(described_class.parse(text)).to eq([nil, "syntax_error"])
    end
  end
end
