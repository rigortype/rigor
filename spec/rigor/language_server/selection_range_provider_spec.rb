# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::SelectionRangeProvider do
  let(:buffer_table)  { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:provider) do
    described_class.new(buffer_table: buffer_table, project_context: project_context)
  end

  let(:uri) { "file:///tmp/sel.rb" }

  describe "#provide" do
    it "returns nil for non-file URIs" do
      expect(provider.provide("untitled:foo", [{ line: 0, character: 0 }])).to be_nil
    end

    it "returns nil when the buffer isn't open" do
      expect(provider.provide("file:///nope.rb", [{ line: 0, character: 0 }])).to be_nil
    end

    it "returns one SelectionRange per requested position" do
      buffer_table.open(uri: uri, bytes: "x = 1\ny = 2\n", version: 1)

      ranges = provider.provide(uri, [{ line: 0, character: 0 }, { line: 1, character: 0 }])
      expect(ranges.size).to eq(2)
    end

    it "builds an outward-chained linked list from innermost to root" do
      # `class Foo; def m; 42; end; end` — selecting on `42`
      # gives [innermost=42, def m, class Foo, root].
      source = <<~RUBY
        class Foo
          def m
            42
          end
        end
      RUBY
      buffer_table.open(uri: uri, bytes: source, version: 1)

      result = provider.provide(uri, [{ line: 2, character: 4 }])
      range = result.first
      expect(range).not_to be_nil

      # Walk the parent chain. Innermost should be the smallest
      # range; each parent strictly contains its child.
      chain = []
      current = range
      while current
        chain << current[:range]
        current = current[:parent]
      end
      expect(chain.size).to be >= 3 # at minimum integer + def + class
      # Each parent should contain its child (start <= child.start
      # and end >= child.end).
      chain.each_cons(2) do |child, parent|
        expect(parent[:start][:line]).to be <= child[:start][:line]
        expect(parent[:end][:line]).to be >= child[:end][:line]
      end
    end
  end
end
