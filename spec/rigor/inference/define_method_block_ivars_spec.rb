# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #1695 — a `define_method` block in a class body runs on an INSTANCE (issue #963 narrows its `self` to
# `Nominal[C]`), but its entry scope still carried the class body's instance-variable bindings: those of the class
# OBJECT. `@label = nil` written in the class body therefore typed the block's `@label.upcase` as a call on nil,
# although Ruby reads the instance's `@label` there. `Scope#with_block_self_type` now drops every ivar binding when
# it narrows a block onto a different `self`, so the read answers `Dynamic` until the body writes it.
RSpec.describe "a define_method block reads the instance's ivars, not the class body's" do
  def diagnostics_for(source)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "subject.rb"), source)
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]),
        cache_store: nil
      )
      guarded_run(runner).diagnostics.reject { |d| d.path.to_s.end_with?(".rigor.yml") }
    end
  end

  def upcase_lines(source)
    diagnostics_for(source).select { |d| d.message.include?("upcase") }.map(&:line)
  end

  it "does not read the class body's `@label = nil` in a statement-level define_method block (the issue)" do
    expect(upcase_lines(<<~RUBY)).to be_empty
      class Store
        @label = nil

        def initialize
          @label = +"x"
        end

        define_method(:shout) { @label.upcase }
        define_method(:whisper) { @label.upcase }
      end
    RUBY
  end

  it "does not read it in a value-position define_method block" do
    expect(upcase_lines(<<~RUBY)).to be_empty
      class Store
        @label = nil

        private define_method(:shout) { @label.upcase }
      end
    RUBY
  end

  it "does not read a class-method body's ivar in a define_method block written there" do
    expect(upcase_lines(<<~RUBY)).to be_empty
      class Store
        def self.build
          @label = nil
          define_method(:shout) { @label.upcase }
        end
      end
    RUBY
  end

  # --- controls: the ivar state that IS the block's own, or whose `self` is unchanged, still reports --------

  it "still reports a nil the define_method block itself wrote" do
    expect(upcase_lines(<<~RUBY)).to eq([6])
      class Store
        @label = nil

        define_method(:shout) do
          @label = nil
          @label.upcase
        end
      end
    RUBY
  end

  it "still reports a nil-only instance ivar read in a def body" do
    expect(upcase_lines(<<~RUBY)).to eq([7])
      class Store
        def initialize
          @label = nil
        end

        def shout
          @label.upcase
        end
      end
    RUBY
  end

  it "still reports the class body's nil in a block whose self is not narrowed" do
    expect(upcase_lines(<<~RUBY)).to eq([4])
      class Store
        @label = nil

        tap { @label.upcase }
      end
    RUBY
  end

  describe "Scope#with_block_self_type" do
    let(:environment) { Rigor::Environment.default }
    let(:outer) do
      Rigor::Scope.empty(environment: environment)
                  .with_self_type(Rigor::Type::Combinator.singleton_of("Store"))
                  .with_ivar(:@label, Rigor::Type::Combinator.constant_of(nil))
    end
    let(:marked_narrowed) { marked_scope.with_block_self_type(Rigor::Type::Combinator.nominal_of("Store")) }

    it "drops the ivar bindings when the narrowed self is a different object" do
      narrowed = outer.with_block_self_type(Rigor::Type::Combinator.nominal_of("Store"))

      expect(narrowed.ivar(:@label)).to be_nil
    end

    it "keeps them when the narrowing keeps the caller's self (an ADR-16 :lexical entry)" do
      narrowed = outer.with_block_self_type(Rigor::Type::Combinator.singleton_of("Store"))

      expect(narrowed.ivar(:@label)).to eq(Rigor::Type::Combinator.constant_of(nil))
    end

    # Every per-ivar carrier the narrowing touches, each with a non-ivar entry beside it that must survive.
    def marked_scope
      string = Rigor::Type::Combinator.nominal_of("String")
      origin = Rigor::Inference::DynamicOrigin::INFERRED_RETURN_UNTYPED
      outer.seed_declaration_sourced_ivar(:@x, string)
           .seed_declaration_sourced_global(:$/, string)
           .with_published_constant_mark(:ivar, :@x)
           .with_published_constant_mark(:global, :$mode)
           .with_indexed_narrowing(:ivar, :@x, :k, string)
           .with_indexed_narrowing(:local, :h, :k, string)
           .with_method_chain_narrowing(:ivar, :@x, :name, string)
           .with_method_chain_narrowing(:local, :h, :name, string)
           .with_guarded_ivar(:@y, string, Rigor::Type::Combinator.untyped)
           .with_bot_guard_classes(:ivar, :@y, ["String"])
           .with_bot_guard_classes(:global, :$g, ["String"])
           .with_ivar_origin(:@x, origin)
           .with_optimistic_ivar(:@x, origin)
    end

    it "drops the ivar marks, narrowings, origins and guard records with the bindings" do
      expect(marked_narrowed.declaration_sourced?(:ivar, :@x)).to be(false)
      expect(marked_narrowed.published_constant_sourced?(:ivar, :@x)).to be(false)
      expect(marked_narrowed.indexed_narrowing(:ivar, :@x, :k)).to be_nil
      expect(marked_narrowed.method_chain_narrowing(:ivar, :@x, :name)).to be_nil
      expect(marked_narrowed.guard_narrowed_ivar?(:@y)).to be(false)
      expect(marked_narrowed.bot_guard_classes_for(:ivar, :@y)).to be_nil
      expect(marked_narrowed.ivar_origin(:@x)).to be_nil
      expect(marked_narrowed.optimistic_ivar(:@x)).to be_nil
    end

    it "keeps every entry that is not an ivar's" do
      string = Rigor::Type::Combinator.nominal_of("String")

      expect(marked_narrowed.declaration_sourced?(:global, :$/)).to be(true)
      expect(marked_narrowed.published_constant_sourced?(:global, :$mode)).to be(true)
      expect(marked_narrowed.indexed_narrowing(:local, :h, :k)).to eq(string)
      expect(marked_narrowed.method_chain_narrowing(:local, :h, :name)).to eq(string)
      expect(marked_narrowed.bot_guard_classes_for(:global, :$g)).to eq(["String"])
    end

    # Review of #1769 — `Set#reject` answers an Array on Ruby 4, and a Set carrier turned Array raised in
    # `with_global_copy_marks` (`merge`) and `join_published_constant_sourced` (`|`).
    it "keeps each carrier's class" do
      marked = marked_scope
      %i[declaration_sourced published_constant_sourced indexed_narrowings method_chain_narrowings
         guard_records bot_guard_classes].each do |carrier|
        expect(marked_narrowed.public_send(carrier).class).to eq(marked.public_send(carrier).class), carrier.to_s
      end
      copied = marked_narrowed.with_declaration_sourced_local(:sep, Rigor::Type::Combinator.nominal_of("String"))
      expect { copied.with_global_copy_marks(:sep, [:$/]) }.not_to raise_error
    end
  end

  it "analyses a Class.new body under a method whose class seeds a marked ivar (review of #1769)" do
    diagnostics = diagnostics_for(<<~RUBY)
      $stdout = $stderr

      class Foo
        def initialize
          @x = nil
        end

        def run
          Class.new do
            out = $stdout
            out.zork
            1.zork
          end
        end
      end
    RUBY

    expect(diagnostics.map(&:message).grep(/internal analyzer error/)).to be_empty
    expect(diagnostics.map(&:message).grep(/zork/)).not_to be_empty
  end
end
