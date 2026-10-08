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

  context "when `class self::X` shadows a real lexical X under an opaque class_eval receiver" do
    %w[class_eval class_exec].each do |meth|
      it "types the body of #{meth} apart from the real Registry::Opaque" do
        source = <<~RUBY
          module Registry
            class Opaque
              def self.real(a) = a
              def helper(a) = a
            end
            REGISTRY = [Class.new].freeze

            REGISTRY.first.#{meth} do
              class self::Opaque
                def self.real = "s"
                self.real
                def helper = :sym
                def go = self.helper
              end
            end
          end
        RUBY

        expect(analyze(source).diagnostics).to eq([])
      end
    end

    it "does not type self in the declined body as the lexical singleton" do
      source = <<~RUBY
        module Registry
          class Opaque; end
          REGISTRY = [Class.new].freeze

          REGISTRY.first.class_eval do
            class self::Opaque
              dump_type(self)
            end
          end
        end
      RUBY

      dumped = analyze(source).diagnostics.map(&:message).grep(/\Adump_type/)

      expect(dumped).not_to be_empty
      expect(dumped.join).not_to include("Registry::Opaque")
    end

    it "declines `module self::M` the same way" do
      source = <<~RUBY
        module Registry
          module M
            def self.real(a) = a
          end
          REGISTRY = [Class.new].freeze

          REGISTRY.first.class_eval do
            module self::M
              def self.real = "s"
              self.real
            end
          end
        end
      RUBY

      expect(analyze(source).diagnostics).to eq([])
    end
  end

  # `class self::X` written straight inside `class << self` defines `#<Class:Foo>::X`, which nothing names. Its
  # empty frame stack is not the top level: an implicit-self call in a `def` there has a receiver Rigor cannot
  # type, so it answers `Dynamic` instead of an unresolved top-level call.
  context "when `self::X` is declared directly inside `class << self`" do
    %w[class module].each do |keyword|
      it "reads implicit-self calls in a `#{keyword} self::X` def as calls on an untyped receiver" do
        source = <<~RUBY
          class Foo
            class << self
              #{keyword} self::Bar
                def x = 1
                def y = x + 1
                def z = helper_attr
                attr_reader :helper_attr
              end
            end
          end
        RUBY

        expect(analyze(source).diagnostics).to eq([])
      end
    end

    it "stays silent on implicit-self calls at the body level and in a nested `class << self`" do
      source = <<~RUBY
        class Foo
          class << self
            class self::Bar
              attr_reader :a
              helper_call
              private
              def x = a
              class << self
                def k = zork
              end
            end
          end
        end
      RUBY

      expect(analyze(source).diagnostics).to eq([])
    end

    it "still checks arity on a nameable `class self::Bar`" do
      source = <<~RUBY
        class Foo
          class self::Bar
            def x(a) = a
          end
        end
        Foo::Bar.new.x
      RUBY

      expect(analyze(source).diagnostics.map(&:rule)).to include("call.wrong-arity")
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
                         "typed.rb" => "def go = Integer.sqrt(1, 2)\n"
                       })

      expect(result.diagnostics.map(&:message)).not_to include(a_string_matching(/internal analyzer error/))
      expect(result.diagnostics.map(&:path)).to include(a_string_ending_with("broken.rb"))
      expect(result.diagnostics.map(&:path)).to include(a_string_ending_with("typed.rb"))
    end

    # A file with a parse error runs no check rules, so the top-level reading is asserted on the scope the
    # rules would consult rather than on a diagnostic.
    it "does not read a def in the nameless body as the top level" do
      root = Prism.parse(<<~RUBY).value
        class foo
          def x = 1
          def y = x + 1
        end
      RUBY
      call = Rigor::Source::NodeWalker.each(root).find { |n| n.is_a?(Prism::CallNode) && n.name == :x }
      scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[call]

      expect(scope.toplevel?).to be(false)
    end

    it "keeps the Prism parse error and raises no internal error" do
      messages = analyze(source).diagnostics.map(&:message)

      expect(messages).to include(a_string_matching(%r{class/module name must be CONSTANT}))
      expect(messages).not_to include(a_string_matching(/internal analyzer error/))
    end
  end
end
