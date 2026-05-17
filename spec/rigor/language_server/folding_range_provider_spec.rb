# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::FoldingRangeProvider do
  let(:buffer_table)  { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:provider) do
    described_class.new(buffer_table: buffer_table, project_context: project_context)
  end

  let(:uri) { "file:///tmp/fold.rb" }

  describe "#provide" do
    it "returns nil for non-file URIs" do
      expect(provider.provide("untitled:foo")).to be_nil
    end

    it "returns nil when the buffer isn't open" do
      expect(provider.provide("file:///nope.rb")).to be_nil
    end

    it "returns an empty array for a single-line buffer" do
      buffer_table.open(uri: uri, bytes: "x = 1\n", version: 1)

      expect(provider.provide(uri)).to eq([])
    end

    it "emits one FoldingRange per multi-line class / def" do
      source = <<~RUBY
        class Foo
          def bar
            1
            2
          end

          def baz
            3
          end
        end
      RUBY
      buffer_table.open(uri: uri, bytes: source, version: 1)

      ranges = provider.provide(uri)
      expect(ranges.size).to eq(3) # outer class + two defs.
      # Outer class spans lines 0..9 (LSP 0-based). endLine = 8
      # (one line before `end` on line 9 in 0-based).
      outer = ranges.max_by { |r| r[:endLine] - r[:startLine] }
      expect(outer[:startLine]).to eq(0)
      expect(outer[:endLine]).to be >= 7
    end

    it "skips single-line constructs (start_line == end_line)" do
      source = "def foo; 1; end\n"
      buffer_table.open(uri: uri, bytes: source, version: 1)

      expect(provider.provide(uri)).to eq([])
    end

    it "emits folds for module + nested class" do
      source = <<~RUBY
        module Outer
          class Inner
            def m
              1
              2
            end
          end
        end
      RUBY
      buffer_table.open(uri: uri, bytes: source, version: 1)

      ranges = provider.provide(uri)
      # module + class + def = 3 folds.
      expect(ranges.size).to eq(3)
    end
  end
end
