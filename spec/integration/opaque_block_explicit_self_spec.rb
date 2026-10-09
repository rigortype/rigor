# frozen_string_literal: true

# Issue #1717 — an explicit `self.m` inside a block whose `self` Rigor does not model.
#
# Issue #316 enters every block body with `self` unmodelled (`Scope#opaque_block_self?`): the yielding
# method may `instance_exec` the block on another object, so the bare `m` there stays silent. The explicit
# `self.m` still typed its receiver as the ENCLOSING `self` and `call.undefined-method` fired on it whenever
# that `self` was RBS-known — `ActionController::Renderers.add(:protobuf) do self.content_type = … end`,
# which Rails runs on the controller, read as a call on `singleton(Protobufable::Renderers)`.
#
# A block whose `self` the engine DOES narrow (`define_method`, a `Class.new` body, an ADR-16
# `block_as_methods:` match) keeps checking against that type, and every silence below is paired with a
# still-fires sibling.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "an explicit self call in an opaque block (#1717)" do
  around do |example|
    Dir.mktmpdir("rigor-opaque-block-self-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # `source` is one file's text, or a `{ "name.rb" => text }` hash for several.
  def undefined_messages(source, rbs, plugin_class: nil)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    files = source.is_a?(Hash) ? source : { "demo.rb" => source }
    files.each { |name, text| File.write(File.join("lib", name), text) }
    File.write(File.join("sig", "demo.rbs"), rbs)
    settings = { "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0 }
    settings["plugins"] = ["rigor-opaqueselftest"] if plugin_class
    Rigor::Plugin.unregister! if plugin_class
    runner = Rigor::Analysis::Runner.new(
      configuration: Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(settings)),
      cache_store: nil,
      **(plugin_class ? { plugin_requirer: ->(_name) { Rigor::Plugin.register(plugin_class) || true } } : {})
    )
    guarded_run(runner, %w[lib]).diagnostics
                                .select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  let(:registry_rbs) do
    <<~RBS
      module Registry
        def self.add: (Symbol) { (untyped) -> untyped } -> nil
      end
      module Renderers
        def self.install!: () -> untyped
      end
      class Widget
        def run: () -> void
      end
    RBS
  end

  # The issue's repro: a writer and a reader through `self.`, beside the bare call that was already silent.
  it "does not report an explicit self call in a block whose self is unmodelled" do
    messages = undefined_messages(<<~RUBY, registry_rbs)
      module Registry
        def self.add(name, &block) = nil
      end

      module Renderers
        def self.install!
          Registry.add(:x) do |message|
            self.content_type = "a"
            self.foo
            bar
            [1].each { self.nested }
          end
          self.direct_miss
        end
      end
    RUBY
    expect(messages).to eq(["undefined method `direct_miss' for singleton(Renderers)"])
  end

  # The indexer's unentered-block walk (a block in an argument position) must agree with the evaluator.
  it "does not report one in a value-position block either" do
    messages = undefined_messages(<<~RUBY, registry_rbs)
      module Registry
        def self.add(name, &block) = nil
      end

      module Renderers
        def self.install!
          x = Registry.add(:x) { self.assigned }
          puts(Registry.add(:y) { self.argument })
          x
        end
      end
    RUBY
    expect(messages).to be_empty
  end

  # `Array#each` keeps the enclosing `self` at runtime, but nothing tells it apart from an `instance_exec`
  # without knowing the callee — the #316 decision, followed here as for the implicit call.
  it "follows #316 for a plain iteration block and keeps checking the method body around it" do
    messages = undefined_messages(<<~RUBY, registry_rbs)
      class Widget
        def run
          [1].each { self.zap }
          self.zap2
        end
      end
    RUBY
    expect(messages).to eq(["undefined method `zap2' for Widget"])
  end

  it "keeps checking a define_method block, whose self the engine narrows" do
    messages = undefined_messages(<<~RUBY, registry_rbs)
      class Widget
        def run = nil
        define_method(:dm) { self.zap3 }
      end
    RUBY
    expect(messages).to eq(["undefined method `zap3' for Widget"])
  end

  # The `define_method` narrowing reads the lexical `self`; inside an opaque block that is the enclosing
  # method's, not the block's, so the narrowed body stays opaque.
  it "leaves a define_method narrowed off an opaque enclosing self opaque" do
    messages = undefined_messages(<<~RUBY, registry_rbs)
      module Registry
        def self.add(name, &block) = nil
      end

      class Widget
        def run = nil

        Registry.add(:x) do
          define_method(:dm) { self.zap3 }
        end
      end
    RUBY
    expect(messages).to be_empty
  end

  # The exemption has a mark of its own: #316's opaque mark also gates `Scope#bindable_top_level_def_for`, so
  # setting THAT mark on a value-position block declined a cross-file top-level def there and the call fell
  # through to `Kernel#format` / `Kernel#select` — three new false positives on correct code.
  it "leaves a cross-file top-level def bound in a value-position block" do
    messages = undefined_messages(
      {
        "helpers.rb" => <<~RUBY,
          def format(x) = 42
          def select(*a) = "s"
        RUBY
        "script.rb" => <<~RUBY
          def report(rows)
            puts(rows.map { |r| format(r).bit_length })
          end
          File.write("out", [1, 2].map { |r| format(r).digits }.inspect)
          puts [1].map { select(1).upcase }
        RUBY
      },
      registry_rbs
    )
    expect(messages).to be_empty
  end

  # The indexer's walk drops the mark at a `def` inside an unentered block, as the evaluator's fresh body
  # scope does: the method's `self` is the class's instance again.
  it "keeps checking a def body written inside a value-position block" do
    messages = undefined_messages(<<~RUBY, registry_rbs)
      module Registry
        def self.add(name, &block) = nil
      end

      class Widget
        def run
          puts(Registry.add(:y) { def h2 = self.zap22 })
        end
      end
    RUBY
    expect(messages).to eq(["undefined method `zap22' for Widget"])
  end

  # A class-creating meta call's body runs on the new class whatever encloses it, so its `self` is known.
  it "keeps checking a Class.new body" do
    messages = undefined_messages(<<~RUBY, "#{registry_rbs}class Klass\nend\n")
      Klass = Class.new do
        self.zap9
      end
    RUBY
    expect(messages).to eq(["undefined method `zap9' for singleton(Klass)"])
  end

  # The indexer's narrowing of a value-position `define_method` keeps the unknown mark when the lexical
  # `self` it reads is itself unknown.
  it "leaves a value-position define_method narrowed off an unknown enclosing self exempt" do
    messages = undefined_messages(<<~RUBY, registry_rbs)
      module Registry
        def self.add(name, &block) = nil
      end

      class Widget
        def run = nil

        Registry.add(:x) do
          puts(define_method(:dm) { self.zap3 })
        end
      end
    RUBY
    expect(messages).to be_empty
  end

  context "with a block_as_methods: narrowing" do
    let(:plugin_class) do
      klass = Class.new(Rigor::Plugin::Base) do
        manifest(
          id: "opaqueselftest",
          version: "0.1.0",
          block_as_methods: [
            Rigor::Plugin::Macro::BlockAsMethod.new(receiver_constraint: "Sinatra::Base", method_names: %i[get])
          ]
        )
      end
      stub_const("FakePluginOpaqueSelfTest", klass)
      klass
    end

    let(:sinatra_rbs) do
      <<~RBS
        module Sinatra
          class Base
            def self.get: (String) ?{ () -> untyped } -> void
            def redirect: (String) -> void
          end
        end
      RBS
    end

    it "keeps checking the narrowed self, in statement and value position" do
      messages = undefined_messages(<<~RUBY, sinatra_rbs, plugin_class: plugin_class)
        Sinatra::Base.get("/a") do
          self.redirect "/b"
          self.nope
        end
        puts(Sinatra::Base.get("/c") { self.nope2 })
      RUBY
      expect(messages).to contain_exactly(
        a_string_including("`nope' for Sinatra::Base"), a_string_including("`nope2' for Sinatra::Base")
      )
    end
  end
end
