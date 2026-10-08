# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1518 — a `class` header that names no class is declined where it is recorded and typed, instead of being
# filed under an empty name that `Type::Combinator.resolve_class_name` refuses with "anonymous class has no name".
RSpec.describe "unnameable class declarations" do
  include RunnerHelpers

  def index(source)
    root = Prism.parse(source).value
    Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root].discovery
  end

  context "when `class self::X` is opened on a receiver no constant names" do
    let(:source) do
      <<~RUBY
        REGISTRY = [Class.new].freeze

        REGISTRY.first.class_eval do
          class self::Opaque
            def m = 1
          end
        end
      RUBY
    end

    it "raises no internal error and reports nothing" do
      expect(analyze(source).diagnostics).to eq([])
    end

    it "registers no class under an empty name" do
      expect(index(source).discovered_classes.keys).not_to include("")
    end

    it "still files Foo::Bar for a constant receiver" do
      tables = index(<<~RUBY)
        class Foo; end
        Foo.class_eval { class self::Bar; end }
      RUBY

      expect(tables.discovered_classes.keys).to include("Foo::Bar")
    end
  end

  context "when the header is a parse-error recovery with no constant" do
    let(:source) do
      <<~RUBY
        class foo < Data.define(:x)
          def m = x
        end

        class Other
          def n = 1
        end
      RUBY
    end

    it "builds the scope index without raising" do
      expect { index(source) }.not_to raise_error
    end

    it "registers no class under an empty name" do
      expect(index(source).discovered_classes.keys).not_to include("")
    end

    it "still indexes the rest of the file" do
      expect(index(source).discovered_classes.keys).to include("Other")
    end

    it "does not stop another file of the project from being analysed" do
      result = analyze(files: {
                         "broken.rb" => "class foo < Data.define(:x); end\n",
                         "typed.rb" => "def go = 1 + \"a\"\n"
                       })

      expect(result.diagnostics.map(&:message)).not_to include(a_string_matching(/internal analyzer error/))
      expect(result.diagnostics.map(&:path)).to include(a_string_ending_with("broken.rb"))
    end

    it "keeps the Prism parse error and raises no internal error" do
      messages = analyze(source).diagnostics.map(&:message)

      expect(messages).to include(a_string_matching(%r{class/module name must be CONSTANT}))
      expect(messages).not_to include(a_string_matching(/internal analyzer error/))
    end
  end
end
