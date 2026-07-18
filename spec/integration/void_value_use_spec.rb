# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"

# The ADR-100 WD4 transitive examples need the bundled `rigor-rbs-inline` plugin for the inline-annotation
# (ADR-93 auto-wire) leaf provenance; same load shape as `spec/integration/plugins/rbs_inline_plugin_spec.rb`.
unless defined?(RBS_INLINE_PLUGIN_LIB)
  RBS_INLINE_PLUGIN_LIB = File.expand_path(
    "../../plugins/rigor-rbs-inline/lib", __dir__
  )
end
$LOAD_PATH.unshift(RBS_INLINE_PLUGIN_LIB) unless $LOAD_PATH.include?(RBS_INLINE_PLUGIN_LIB)
require "rigor-rbs-inline"

# ADR-100 WD2 — `static.value-use.void`. A value recovered from an author-declared `-> void` return, used in
# value context, is a misuse: the author said "do not rely on this return", and the engine widened it to
# `top`. The diagnostic is FP-narrow (only an author-written `-> void`, only the direct-dispatch path) and,
# because a new required diagnostic is an ADR-50 WD1 compatibility change, it ships `:off` and reaches a user
# only through the `use-of-void-value` bleeding-edge feature.
#
# NOTE on the fixture method: the acceptance example `x = puts(1)` does not apply against rbs 4.0.2 — its
# `Kernel#puts` return is `nil`, not `void`. The rule's normative trigger is "an author *wrote* `-> void`", so
# the fixture declares one directly (`VoidBox#log`), which is the strongest form of the same case.
RSpec.describe "static.value-use.void reporting" do
  let(:void_box_rbs) do
    <<~RBS
      class VoidBox
        def log: (String) -> void
        def peek: () -> top
      end
    RBS
  end

  # Each call form pairs a `-> void` use (should fire when adopted) against a `-> top` use in the same value
  # position (must stay silent — the false-positive proof), plus a bare-statement `-> void` call (statement
  # context — accepted, silent).
  let(:app_rb) do
    <<~RUBY
      l = VoidBox.new
      assigned = l.log("assign")
      l.log("bare statement")
      l.log("receiver").to_s
      store(l.log("argument"))
      legit_assign = l.peek
      legit_recv = l.peek.to_s
    RUBY
  end

  def write_project
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "void_box.rbs"), void_box_rbs)
    File.write("app.rb", app_rb)
  end

  def config(bleeding_edge: nil)
    settings = Rigor::Configuration::DEFAULTS.merge(
      "paths" => %w[app.rb], "signature_paths" => %w[sig]
    )
    settings = settings.merge("bleeding_edge" => bleeding_edge) unless bleeding_edge.nil?
    Rigor::Configuration.new(settings)
  end

  def run(configuration)
    Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil).run(%w[app.rb])
  end

  def void_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "static.value-use.void" }
  end

  around do |example|
    Dir.mktmpdir("rigor-void-value-use-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  it "fires nothing by default (the diagnostic is bleeding-edge-gated)" do
    write_project
    expect(void_diagnostics(run(config))).to be_empty
  end

  context "when the project adopts the use-of-void-value feature" do
    it "fires only on the value-context uses of the `-> void` return" do
      write_project
      diagnostics = void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))

      # The assignment (L2), receiver (L4), and argument (L5) uses fire; the bare statement (L3) and both
      # legitimate `-> top` uses (L6, L7) stay silent.
      expect(diagnostics.map(&:line)).to contain_exactly(2, 4, 5)
      expect(diagnostics).to all(have_attributes(severity: :warning))
      expect(diagnostics.first.message).to include("VoidBox#log", "-> void")
    end

    it "is adoptable via the `all` selector too" do
      write_project
      diagnostics = void_diagnostics(run(config(bleeding_edge: true)))
      expect(diagnostics.map(&:line)).to contain_exactly(2, 4, 5)
    end

    it "is suppressible with an in-source `# rigor:disable` comment" do
      FileUtils.mkdir_p("sig")
      File.write(File.join("sig", "void_box.rbs"), void_box_rbs)
      File.write("app.rb", <<~RUBY)
        l = VoidBox.new
        assigned = l.log("x") # rigor:disable static.value-use.void
      RUBY
      expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
    end
  end

  # ADR-100 WD4 — the transitive case: `def bar; foo; end` where `foo` is author-declared `-> void` and
  # `bar`'s own signature declares nothing. The lazy {Rigor::Inference::VoidTailSummary} chain admits `bar`
  # (sole-return-path body, implicit-self tail resolving on the same owner) and records the LEAF as the
  # origin, so the diagnostic still names the author's `-> void` method. Every fixture is a heredoc so the
  # line numbers asserted below are the literal source lines.
  describe "the transitive case (ADR-100 WD4)" do
    def write_transitive_project(rbs:, source:)
      FileUtils.mkdir_p("sig")
      File.write(File.join("sig", "void_repro.rbs"), rbs)
      File.write("app.rb", source)
    end

    let(:leaf_only_rbs) do
      <<~RBS
        class VoidRepro
          def foo: () -> void
        end
      RBS
    end

    context "with a hand-written partial sig (leaf declared, intermediates absent)" do
      it "fires on one-hop and two-hop value uses, naming the leaf, with every caller defined ABOVE its callee" do
        # The callers sit above the callees on purpose: the lazy summary is consulted at dispatch time
        # against the whole-file discovery index, so lexical order must not matter (the eager
        # record-at-body-evaluation design this replaced would miss these).
        write_transitive_project(rbs: leaf_only_rbs, source: <<~RUBY)
          class VoidRepro
            def use_bar
              b = bar
              b
            end

            def bar
              foo
            end

            def use_baz
              c = baz
              c
            end

            def baz
              bar
            end

            def foo; end
          end
        RUBY
        diagnostics = void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))

        # L3 (`b = bar`, one hop) and L12 (`c = baz`, two hops) fire; the statement-position tails inside
        # `bar` / `baz` (L8, L17) stay silent.
        expect(diagnostics.map(&:line)).to contain_exactly(3, 12)
        expect(diagnostics).to all(have_attributes(severity: :warning))
        expect(diagnostics.map(&:message)).to all(include("VoidRepro#foo", "-> void"))
      end

      it "stays silent for a statement-position transitive call" do
        write_transitive_project(rbs: leaf_only_rbs, source: <<~RUBY)
          class VoidRepro
            def run
              bar
              nil
            end

            def bar
              foo
            end

            def foo; end
          end
        RUBY
        expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
      end

      it "stays silent when the intermediate body contains a return (bare `return` included)" do
        write_transitive_project(rbs: leaf_only_rbs, source: <<~RUBY)
          class VoidRepro
            def use_bar
              b = bar
              b
            end

            def bar
              return if $skip
              foo
            end

            def foo; end
          end
        RUBY
        expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
      end

      it "stays silent when the intermediate def carries a rescue clause" do
        write_transitive_project(rbs: leaf_only_rbs, source: <<~RUBY)
          class VoidRepro
            def use_bar
              b = bar
              b
            end

            def bar
              foo
            rescue StandardError
              nil
            end

            def foo; end
          end
        RUBY
        expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
      end

      it "stays silent for an explicit-receiver tail" do
        write_transitive_project(rbs: leaf_only_rbs, source: <<~RUBY)
          class VoidRepro
            def use_bar
              b = bar
              b
            end

            def bar
              other.foo
            end

            def other
              VoidRepro.new
            end

            def foo; end
          end
        RUBY
        expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
      end

      it "stays silent when the intermediate's own RBS declares a concrete return" do
        write_transitive_project(rbs: <<~RBS, source: <<~RUBY)
          class VoidRepro
            def foo: () -> void
            def bar: () -> Integer
          end
        RBS
          class VoidRepro
            def use_bar
              b = bar
              b
            end

            def bar
              foo
            end

            def foo; end
          end
        RUBY
        expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
      end

      it "stays silent when the tail calls a non-void RBS method" do
        write_transitive_project(rbs: <<~RBS, source: <<~RUBY)
          class VoidRepro
            def foo: () -> void
            def peek: () -> top
          end
        RBS
          class VoidRepro
            def use_bar
              b = bar
              b
            end

            def bar
              peek
            end

            def foo; end
          end
        RUBY
        expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
      end

      it "stays silent (and terminates) on mutual recursion between two defs" do
        write_transitive_project(rbs: leaf_only_rbs, source: <<~RUBY)
          class VoidRepro
            def use_ping
              x = ping
              x
            end

            def ping
              pong
            end

            def pong
              ping
            end

            def foo; end
          end
        RUBY
        expect(void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))).to be_empty
      end

      it "fires on the singleton side, where implicit self resolves to the singleton kind" do
        # Inside a `def self.` body, implicit self is `Singleton[VoidRepro]`, so the chain resolves through
        # the singleton tables (`singleton_def_for` / singleton RBS) and the leaf label uses the `.` form.
        write_transitive_project(rbs: <<~RBS, source: <<~RUBY)
          class VoidRepro
            def self.foo: () -> void
          end
        RBS
          class VoidRepro
            def self.use_bar
              b = bar
              b
            end

            def self.bar
              foo
            end

            def self.foo; end
          end
        RUBY
        diagnostics = void_diagnostics(run(config(bleeding_edge: ["use-of-void-value"])))
        expect(diagnostics.map(&:line)).to contain_exactly(3)
        expect(diagnostics.first.message).to include("VoidRepro.foo")
      end
    end

    context "with an inline `#:` annotation (the ADR-93 auto-wire leaf provenance)" do
      # The rigor-rbs-inline synthesizer contributes `def foo: () -> void` for the annotated leaf AND a
      # `def bar: () -> untyped` skeleton for every un-annotated def of the gated-in file, so the
      # intermediate's call is answered by RbsDispatch — the other serving path the result-independent
      # consult covers (the hand-written-sig path above is answered by ExpressionTyper body inference).
      before { Rigor::Plugin.unregister! }
      after { Rigor::Plugin.unregister! }

      def inline_config
        Rigor::Configuration.new(
          Rigor::Configuration::DEFAULTS.merge(
            "paths" => %w[app.rb],
            "plugins" => ["rigor-rbs-inline"],
            "bleeding_edge" => ["use-of-void-value"]
          )
        )
      end

      def run_with_rbs_inline(configuration)
        requirer = lambda do |_name|
          Rigor::Plugin.register(Rigor::Plugin::RbsInline)
          true
        end
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: nil, plugin_requirer: requirer
        ).run(%w[app.rb])
      end

      it "fires on the one-hop value use with the inline-annotated leaf as origin" do
        File.write("app.rb", <<~RUBY)
          class VoidRepro
            #: () -> void
            def foo; end

            def bar
              foo
            end

            def use_bar
              b = bar
              b
            end
          end
        RUBY
        diagnostics = void_diagnostics(run_with_rbs_inline(inline_config))
        expect(diagnostics.map(&:line)).to contain_exactly(10)
        expect(diagnostics.first.message).to include("VoidRepro#foo")
      end
    end
  end
end
