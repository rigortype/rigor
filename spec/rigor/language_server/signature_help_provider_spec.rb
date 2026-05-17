# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

RSpec.describe Rigor::LanguageServer::SignatureHelpProvider do
  let(:buffer_table)  { Rigor::LanguageServer::BufferTable.new }
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:project_context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }
  let(:provider) do
    described_class.new(buffer_table: buffer_table, project_context: project_context)
  end

  let(:uri) { "file:///tmp/sig.rb" }

  describe "#provide" do
    it "returns nil for non-file URIs" do
      expect(provider.provide(uri: "untitled:foo", line: 0, character: 0)).to be_nil
    end

    it "returns nil when the buffer isn't open" do
      expect(provider.provide(uri: "file:///nope.rb", line: 0, character: 0)).to be_nil
    end

    it "returns nil when the buffer has parse errors AND no sentinel patch applies" do
      buffer_table.open(uri: uri, bytes: "def broken\n", version: 1)
      expect(provider.provide(uri: uri, line: 0, character: 0)).to be_nil
    end

    it "returns the method signature for `\"hi\".center(|`" do
      # `"hi".center(` — buffer fails to parse; sentinel patches
      # `__rigor_lsp_arg_sentinel__` after the `(` so Prism gets
      # a complete CallNode. The signature should reflect
      # String#center's first overload.
      buffer_table.open(uri: uri, bytes: "\"hi\".center(\n", version: 1)
      result = provider.provide(uri: uri, line: 0, character: 12)

      expect(result).not_to be_nil
      expect(result[:signatures].first[:label]).to include("center")
      expect(result[:activeSignature]).to eq(0)
      expect(result[:activeParameter]).to eq(0)
    end

    it "advances activeParameter past commas in the argument list" do
      # Cursor sits after the first comma → activeParameter = 1.
      buffer_table.open(uri: uri, bytes: "\"hi\".center(10,\n", version: 1)
      result = provider.provide(uri: uri, line: 0, character: 15)

      expect(result).not_to be_nil
      expect(result[:activeParameter]).to eq(1)
    end

    it "returns the signature for a clean (already-complete) call" do
      # `"hi".center(10, "*")` — buffer parses cleanly; cursor on
      # an argument. The provider should still surface the
      # signature.
      buffer_table.open(uri: uri, bytes: "\"hi\".center(10, \"*\")\n", version: 1)
      result = provider.provide(uri: uri, line: 0, character: 12)

      expect(result).not_to be_nil
      expect(result[:signatures].first[:label]).to include("center")
    end

    it "returns nil when the cursor isn't inside a method call" do
      buffer_table.open(uri: uri, bytes: "x = 1\n", version: 1)

      expect(provider.provide(uri: uri, line: 0, character: 4)).to be_nil
    end

    describe "RBS documentation field (slice C3)" do
      it "attaches the method's RBS comments to each SignatureInformation" do
        # `String#center` ships with rdoc comments in core RBS;
        # the documentation field should carry them.
        buffer_table.open(uri: uri, bytes: "\"hi\".center(\n", version: 1)
        result = provider.provide(uri: uri, line: 0, character: 12)

        first = result[:signatures].first
        expect(first[:documentation]).to include(kind: "markdown")
        expect(first[:documentation][:value]).not_to be_empty
      end

      it "omits the documentation field when the method has no RBS comments" do
        # Most analyzer-internal classes ship without rdoc; use a
        # definition known to be comment-less by stubbing a
        # minimal `RBS::Definition::Method`-shaped double.
        require "rbs"
        empty_comments_def = Class.new do
          def method_types
            [RBS::Parser.parse_method_type("() -> String")]
          end

          def comments
            []
          end
        end.new

        allow(Rigor::Reflection).to receive(:instance_method_definition)
          .and_return(empty_comments_def)

        buffer_table.open(uri: uri, bytes: "\"hi\".upcase(\n", version: 1)
        result = provider.provide(uri: uri, line: 0, character: 12)

        expect(result[:signatures].first).not_to include(:documentation)
      end
    end

    describe "multi-overload presentation (slice C2)" do
      it "surfaces every overload of a multi-signature method" do
        # `Array#fetch` has multiple overloads in core RBS:
        # `(int) -> Elem`, `(int, X) -> Elem | X`, etc.
        # Slice C2 should emit one SignatureInformation per overload.
        buffer_table.open(uri: uri, bytes: "[1, 2].fetch(\n", version: 1)
        result = provider.provide(uri: uri, line: 0, character: 13)

        expect(result).not_to be_nil
        expect(result[:signatures].size).to be > 1
        labels = result[:signatures].map { |s| s[:label] }
        expect(labels).to all(start_with("fetch"))
      end
    end
  end
end
