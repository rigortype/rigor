# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::DocumentSymbolProvider do
  let(:buffer_table)  { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:provider) do
    described_class.new(buffer_table: buffer_table, configuration: configuration)
  end

  let(:uri) { "file:///abs/foo.rb" }

  describe "#provide" do
    it "returns nil for non-file URIs" do
      expect(provider.provide("untitled:Foo")).to be_nil
    end

    it "returns nil when the buffer isn't open" do
      expect(provider.provide("file:///nope.rb")).to be_nil
    end

    it "returns an empty array for a buffer with no class / module / def" do
      buffer_table.open(uri: uri, bytes: "x = 1\n", version: 1)

      expect(provider.provide(uri)).to eq([])
    end

    it "surfaces a top-level def as a Function symbol (kind 12)" do
      buffer_table.open(uri: uri, bytes: "def foo\n  1\nend\n", version: 1)

      symbols = provider.provide(uri)
      expect(symbols.size).to eq(1)
      expect(symbols.first).to include(name: "foo", kind: 12)
    end

    it "surfaces a class with nested methods" do
      buffer_table.open(uri: uri, bytes: <<~RUBY, version: 1)
        class Foo
          def bar
            1
          end

          def self.baz
            2
          end
        end
      RUBY

      symbols = provider.provide(uri)
      expect(symbols.size).to eq(1)
      class_sym = symbols.first
      expect(class_sym).to include(name: "Foo", kind: 5)
      expect(class_sym[:children].map { |c| [c[:name], c[:kind]] }).to eq(
        [["bar", 6], ["self.baz", 6]]
      )
    end

    it "surfaces a module with nested class" do
      buffer_table.open(uri: uri, bytes: <<~RUBY, version: 1)
        module Outer
          class Inner
            def m
              1
            end
          end
        end
      RUBY

      symbols = provider.provide(uri)
      expect(symbols.size).to eq(1)
      expect(symbols.first[:kind]).to eq(2)   # Module
      expect(symbols.first[:name]).to eq("Outer")
      inner = symbols.first[:children].first
      expect(inner[:kind]).to eq(5)            # Class
      expect(inner[:name]).to eq("Inner")
      expect(inner[:children].first[:name]).to eq("m")
    end

    it "renders qualified-constant class names (e.g. Foo::Bar)" do
      buffer_table.open(uri: uri, bytes: "class Foo::Bar; end\n", version: 1)

      symbols = provider.provide(uri)
      expect(symbols.first[:name]).to eq("Foo::Bar")
    end

    it "uses 0-based positions in range/selectionRange" do
      buffer_table.open(uri: uri, bytes: "class Foo\nend\n", version: 1)

      class_sym = provider.provide(uri).first
      # First line of source = LSP line 0.
      expect(class_sym[:range][:start][:line]).to eq(0)
      expect(class_sym[:selectionRange][:start][:line]).to eq(0)
    end
  end
end
