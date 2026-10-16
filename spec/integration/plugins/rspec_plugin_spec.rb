# frozen_string_literal: true

# Integration spec for `plugins/rigor-rspec/`. Tier 3A of the Rails plugins roadmap. Deliberately scoped — only
# flags duplicate `let` / `subject` declarations and self-referencing let blocks. The heavier mock-target /
# let-typo detection is out of scope for v0.1.0.

require "spec_helper"

RSPEC_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-rspec/lib", __dir__)
$LOAD_PATH.unshift(RSPEC_PLUGIN_LIB) unless $LOAD_PATH.include?(RSPEC_PLUGIN_LIB)
require "rigor-rspec"

RSpec.describe "plugins/rigor-rspec" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Rspec }

  describe "duplicate-let detection" do
    it "flags two `let(:name)` declarations in the same scope" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { :first }
            let(:user) { :second }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:warning)
      expect(err.message).to include("duplicate `let(:user)`")
      expect(err.message).to include("first declared at line 2")
    end

    it "flags `subject(:name)` duplicates" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "Greeting" do
            subject(:greeting) { "hi" }
            subject(:greeting) { "hello" }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.message).to include("subject(:greeting)")
    end

    it "does NOT flag `let` declarations in different scopes (nested context)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { :outer }
            context "when inner" do
              let(:user) { :inner }
            end
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "duplicate-let" }
      expect(diags).to be_empty
    end

    it "flags THREE duplicates with two diagnostics (the second and third occurrences)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:foo) { 1 }
            let(:foo) { 2 }
            let(:foo) { 3 }
          end
        RUBY
      )
      dupes = plugin_diagnostics(result).select { |d| d.rule == "duplicate-let" }
      expect(dupes.size).to eq(2)
    end
  end

  describe "self-reference detection" do
    it "flags `let(:user) { user }` (literal self-reference)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "User" do
            let(:user) { user }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "self-reference" }
      expect(err).not_to be_nil
      expect(err.severity).to eq(:error)
      expect(err.message).to include("`user`")
    end

    it "flags `let(:value) { value.something }` (deeper expression)" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:value) { value.upcase }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "self-reference" }
      expect(err).not_to be_nil
    end

    it "does NOT flag a let referencing a different let" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:user) { :alice }
            let(:greeting) { "Hello, \#{user}" }
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "self-reference" }
      expect(diags).to be_empty
    end

    it "does NOT flag a let whose body uses an unrelated method" do
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            let(:user) { build_user }
          end
        RUBY
      )
      diags = plugin_diagnostics(result).select { |d| d.rule == "self-reference" }
      expect(diags).to be_empty
    end
  end

  # Pillar 2 Slice 1 — `expect(x).to MATCHER` narrows `x` downstream in the same `it` body. The plugin's
  # `narrowing_facts` (method-gated on `to` / `not_to` / `to_not`, ADR-37 slice 2) recognises the call shape
  # and emits a `post_return_fact` targeting local `x`; the engine's `apply_plugin_assertions` → `:local`
  # target_kind branch narrows the local in the surrounding scope.
  describe "matcher narrowing (Pillar 2 Slice 1)" do
    def parse_call_node(source)
      Prism.parse(source, scopes: [[:x]]).value.statements.body.first
    end

    let(:plugin) { plugin_class.allocate }

    context "when matcher is be_a(Class)" do
      it "emits a :local post_return_fact narrowing to Nominal[Class]" do
        call_node = parse_call_node("expect(x).to be_a(String)")
        facts = plugin.narrowing_facts_for(call_node: call_node, scope: nil)
        fact = facts.first

        expect(facts).not_to be_empty
        expect(fact.target_kind).to eq(:local)
        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end

    context "when matcher is be_kind_of(Class)" do
      it "emits the same shape as be_a" do
        call_node = parse_call_node("expect(x).to be_kind_of(Integer)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      end
    end

    context "when matcher is be_instance_of(Class)" do
      it "emits a :local fact for the named class" do
        call_node = parse_call_node("expect(x).to be_instance_of(Float)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("Float"))
      end
    end

    context "when matcher is be_nil" do
      it "emits a :local fact narrowing to Constant<nil>" do
        call_node = parse_call_node("expect(x).to be_nil")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
      end
    end

    def nominal(name) = Rigor::Type::Combinator.nominal_of(name)
    def constant(value) = Rigor::Type::Combinator.constant_of(value)
    def union(*members) = Rigor::Type::Combinator.union(*members)

    # The type of the fact `source` emits with `x` bound to `x_type`, or nil when it emits none.
    def equality_fact_type(source, x_type)
      scope = Rigor::Scope.empty.with_local(:x, x_type)
      plugin.narrowing_facts_for(call_node: parse_call_node(source), scope: scope).first&.type
    end

    context "when matcher is eq(literal)" do
      it "narrows to Constant<integer> for an integer literal" do
        expect(equality_fact_type("expect(x).to eq(42)", nominal("Integer"))).to eq(constant(42))
      end

      it "narrows to Constant<string> for a string literal" do
        expect(equality_fact_type('expect(x).to eq("hi")', nominal("String"))).to eq(constant("hi"))
      end

      it "narrows to Constant<symbol> for a symbol literal" do
        expect(equality_fact_type("expect(x).to eq(:foo)", nominal("Symbol"))).to eq(constant(:foo))
      end

      it "narrows to Constant<true> for a true literal" do
        expect(equality_fact_type("expect(x).to eq(true)", union(constant(true), constant(false))))
          .to eq(constant(true))
      end

      # Issue #1807 — `eq` passes on `x == literal` with the local as the receiver, so the fact meets the local's
      # current type and never replaces it.
      it "drops a core member whose built-in equality with the literal is false" do
        expect(equality_fact_type("expect(x).to eq(9)", union(nominal("Integer"), constant(nil))))
          .to eq(constant(9))
        expect(equality_fact_type("expect(x).to eq(9)", union(constant(1), constant(9)))).to eq(constant(9))
      end

      it "drops a core member of a non-numeric class other than the literal's" do
        expect(equality_fact_type("expect(x).to eq(9)", union(nominal("String"), nominal("Integer"))))
          .to eq(constant(9))
      end

      it "narrows a refinement of the literal's class and drops one of another core class" do
        non_empty_string = Rigor::Type::Combinator.non_empty_string
        expect(equality_fact_type('expect(x).to eq("3")', union(non_empty_string, constant(nil))))
          .to eq(constant("3"))
        expect(equality_fact_type("expect(x).to eq(3)", union(non_empty_string, nominal("Integer"))))
          .to eq(constant(3))
        lowercase = Rigor::Type::Combinator.lowercase_string
        expect(equality_fact_type('expect(x).to eq("a")', union(lowercase, constant(nil)))).to eq(constant("a"))
      end

      it "narrows an Intersection of refinements of the literal's class" do
        lowercase = Rigor::Type::Combinator.non_empty_lowercase_string
        expect(equality_fact_type('expect(x).to eq("a")', union(lowercase, constant(nil)))).to eq(constant("a"))
      end

      it "is silent for an Intersection whose parts do not all belong to one core class" do
        mixed = Rigor::Type::Combinator.intersection(Rigor::Type::Combinator.lowercase_string, nominal("Greeting"))
        expect(mixed).to be_a(Rigor::Type::Intersection)
        expect(equality_fact_type('expect(x).to eq("a")', union(mixed, constant(nil)))).to be_nil
      end

      it "narrows a FloatRange member to a Float literal" do
        range = Rigor::Type::Combinator.float_range(0.0, 2.0)
        expect(equality_fact_type("expect(x).to eq(1.5)", union(range, constant(nil)))).to eq(constant(1.5))
      end

      it "narrows an IntegerRange member that covers the literal and drops one that does not" do
        expect(equality_fact_type("expect(x).to eq(9)", Rigor::Type::Combinator.integer_range(0, 9)))
          .to eq(constant(9))
        expect(equality_fact_type("expect(x).to eq(9)", Rigor::Type::Combinator.integer_range(0, 5))).to be_nil
      end

      it "keeps a core numeric member of another class, which can equal the literal" do
        expect(equality_fact_type("expect(x).to eq(1)", union(nominal("Integer"), nominal("Float"))))
          .to eq(union(constant(1), nominal("Float")))
        expect(equality_fact_type("expect(x).to eq(1)", nominal("Rational"))).to eq(nominal("Rational"))
        expect(equality_fact_type("expect(x).to eq(1.0)", nominal("Integer"))).to eq(nominal("Integer"))
      end

      it "keeps a Float member for a zero Float literal, which -0.0 also equals" do
        expect(equality_fact_type("expect(x).to eq(0.0)", nominal("Float"))).to eq(nominal("Float"))
      end

      it "is silent when a member may define its own ==, even for an identity literal" do
        %w[nil true :sym 9].each do |literal|
          expect(equality_fact_type("expect(x).to eq(#{literal})", nominal("ModInt"))).to be_nil
          expect(equality_fact_type("expect(x).to eq(#{literal})", union(nominal("ModInt"), constant(nil))))
            .to be_nil
        end
        expect(equality_fact_type("expect(x).to eq(1)", nominal("Numeric"))).to be_nil
      end

      it "is silent for a Dynamic local, an unbound local, and without a scope" do
        expect(equality_fact_type("expect(x).to eq(9)", Rigor::Type::Combinator.untyped)).to be_nil
        expect(plugin.narrowing_facts_for(call_node: parse_call_node("expect(x).to eq(9)"), scope: Rigor::Scope.empty))
          .to be_empty
        expect(plugin.narrowing_facts_for(call_node: parse_call_node("expect(x).to eq(9)"), scope: nil)).to be_empty
        analyzer = Rigor::Plugin::Rspec::MatcherAnalyzer
        expect(analyzer.contribution_for(parse_call_node("expect(x).to eq(9)"), scope: nil)).to be_nil
      end

      it "is silent when no member can equal the literal" do
        expect(equality_fact_type("expect(x).to eq(9)", constant(nil))).to be_nil
      end

      it "is silent for a non-literal argument" do
        call_node = parse_call_node("expect(x).to eq(some_method)")

        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end
    end

    context "when matcher is eql(literal)" do
      it "shares the eq path" do
        expect(equality_fact_type("expect(x).to eql(0)", nominal("Integer"))).to eq(constant(0))
      end

      it "drops a core numeric member of another class, since eql? compares classes" do
        expect(equality_fact_type("expect(x).to eql(1)", union(nominal("Integer"), nominal("Float"))))
          .to eq(constant(1))
        expect(equality_fact_type("expect(x).to eql(1)", union(constant(1), constant(1.0)))).to eq(constant(1))
      end

      it "is silent when a member may define its own eql?" do
        expect(equality_fact_type("expect(x).to eql(1)", union(nominal("Integer"), nominal("ModInt")))).to be_nil
      end
    end

    context "when matcher is match(/regex/)" do
      it "narrows x to String for a regex literal arg" do
        call_node = parse_call_node("expect(x).to match(/\\Afoo\\z/)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end

      it "is silent for a non-regex argument" do
        call_node = parse_call_node('expect(x).to match("foo")')
        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end
    end

    context "when assertion verb is not_to" do
      it "emits a negative fact for not_to be_nil" do
        call_node = parse_call_node("expect(x).not_to be_nil")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.target_name).to eq(:x)
        expect(fact.type).to eq(Rigor::Type::Combinator.constant_of(nil))
        expect(fact.negative).to be(true)
      end

      it "emits a negative Constant fact for not_to eq(literal) whatever the local's type" do
        call_node = parse_call_node("expect(x).not_to eq(9)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(constant(9))
        expect(fact.negative).to be(true)
      end

      it "emits a negative fact for not_to be_a(T)" do
        call_node = parse_call_node("expect(x).not_to be_a(String)")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.type).to eq(Rigor::Type::Combinator.nominal_of("String"))
        expect(fact.negative).to be(true)
      end
    end

    context "when assertion verb is to_not (older spelling)" do
      it "behaves like not_to" do
        call_node = parse_call_node("expect(x).to_not be_nil")
        fact = plugin.narrowing_facts_for(call_node: call_node, scope: nil).first

        expect(fact.negative).to be(true)
      end
    end

    context "with non-matching call shapes" do
      it "is silent for expect(non_local).to MATCHER" do
        # expect(foo.bar) — the arg isn't a LocalVariableReadNode, so the analyzer cannot name a narrowing target.
        call_node = parse_call_node("expect(foo.bar).to be_a(String)")
        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end

      it "is silent for expect { block }.to raise_error(...)" do
        # Block form doesn't match the call shape; future slices might add support, but for now the analyzer
        # drops out.
        call_node = parse_call_node("expect { foo }.to raise_error(StandardError)")
        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end

      it "is silent for an unrecognised matcher (be_truthy queued for follow-up)" do
        call_node = parse_call_node("expect(x).to be_truthy")
        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end

      it "is silent for a bare method call that isn't `.to`" do
        call_node = parse_call_node("foo(x)")
        expect(plugin.narrowing_facts_for(call_node: call_node, scope: nil)).to be_empty
      end
    end

    # End-to-end: the plugin's contribution flows through the engine's `apply_plugin_assertions` → `:local`
    # branch and narrows the local so a downstream `.upcase` / `.+` / etc. resolves cleanly.
    context "when running end-to-end through the engine" do
      # Runs `body` as `T#case_eq(x)` with `x` declared `x_type` in `sig/`, plus `patch` as an analysed file.
      def run_case_eq(x_type, body, patch: nil)
        files = patch ? { "patch.rb" => patch } : {}
        source = "class T\n  def case_eq(x)\n#{body.gsub(/^/, '    ')}  end\nend\n"
        run_plugin(
          source: source,
          files: files.merge("sig/t.rbs" => "class T\n  def case_eq: (#{x_type}) -> void\nend\n"),
          paths: ["demo.rb", *files.keys],
          signature_paths: ["sig"]
        )
      end

      def dumped_types(result)
        result.diagnostics.select { |d| d.rule == "dump.type" }.map { |d| d.message.delete_prefix("dump_type: ") }
      end

      # Guard: `x` reads as String here even when MatcherAnalyzer emits no be_a fact, so this pins the end-to-end
      # result, not the plugin's be_a path (the unit examples above pin that).
      it "removes the possible-nil-receiver after expect(x).to be_a(String)" do
        result = run_case_eq("String?", "expect(x).to be_a(String)\nx.upcase\n")
        nil_recv = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        expect(nil_recv).to be_empty
      end

      it "narrows x to Constant<42> after expect(x).to eq(42) — downstream `x + 1` resolves" do
        result = run_case_eq("Integer?", "expect(x).to eq(42)\nx + 1\n")
        nil_recv = result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }
        expect(nil_recv).to be_empty
      end

      # Issue #1807 — the local is `==`'s receiver, so its own `==` decides `eq`.
      it "keeps an RBS-less local with its own == at its type after eq of any literal" do
        result = run_plugin(
          source: <<~RUBY
            class ModInt
              def initialize(value) = @value = value % 7
              def to_i = @value
              def ==(other) = to_i == other.to_i
              def inc! = @value += 1
            end

            m = ModInt.new(16)
            expect(m).to eq(9)
            m.inc!
            expect(m).to eq(nil)
            m.inc!
            expect(m).to eq(:sym)
            m.inc!
          RUBY
        )
        expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
      end

      it "removes nil from a decimal-int-string? local after eq of a String literal" do
        result = run_case_eq("Integer?", <<~RUBY)
          y = x && x.to_s
          expect(y).to eq("3")
          dump_type(y)
          y.length
        RUBY
        expect(dumped_types(result)).to eq(['"3"'])
        expect(result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }).to be_empty
      end

      it "removes nil from a non-empty-string? local after eq of a String literal" do
        result = run_case_eq("String?", <<~RUBY)
          y = x && x + "!"
          expect(y).to eq("a!")
          dump_type(y)
          y.length
        RUBY
        expect(dumped_types(result)).to eq(['"a!"'])
        expect(result.diagnostics.select { |d| d.rule == "call.possible-nil-receiver" }).to be_empty
      end

      it "still narrows when the project reopens the literal's class with other methods only" do
        patch = "class String\n  def shout = upcase + \"!\"\nend\n"
        result = run_case_eq("String?", "expect(x).to eq(\"a\")\ndump_type(x)\n", patch: patch)
        expect(dumped_types(result)).to eq(['"a"'])
      end

      it "keeps the local's type when the project defines == on the literal's class with define_method" do
        result = run_plugin(
          source: <<~RUBY
            class Integer
              define_method(:==) { |_other| true }
            end

            x = rand(10)
            expect(x).to eq(9)
            dump_type(x)
          RUBY
        )
        expect(dumped_types(result)).not_to include("9")
      end

      it "keeps the local's type when another file defines == on the literal's class" do
        patch = "class String\n  def ==(other) = true\nend\n"
        result = run_case_eq("String?", "expect(x).to eq(\"a\")\ndump_type(x)\n", patch: patch)
        expect(dumped_types(result)).to eq(["String?"])
      end

      it "keeps a member whose class the project gives its own ==, and narrows the rest" do
        patch = "class Symbol\n  def ==(other) = true\nend\n"
        result = run_case_eq("Symbol | Integer | nil", "expect(x).to eq(9)\ndump_type(x)\n", patch: patch)
        expect(dumped_types(result)).to eq(["9 | Symbol"])
      end

      # `Integer#==` runs `other == self` for a non-numeric argument, so the literal's own `==` decides there.
      it "gives no fact when the project defines == on the literal's class, though a kept member survives" do
        patch = "class Symbol\n  def ==(other) = true\nend\nclass String\n  def ==(other) = true\nend\n"
        result = run_case_eq("Symbol | Integer", "expect(x).to eq(\"a\")\ndump_type(x)\n", patch: patch)
        expect(dumped_types(result)).to eq(["Integer | Symbol"])
      end

      it "keeps a member whose operator a reopened core ancestor up to its owner defines" do
        patch = "class Numeric\n  def eql?(other) = true\nend\n"
        expect(dumped_types(run_case_eq("Integer", "expect(x).to eql(9)\ndump_type(x)\n", patch: patch)))
          .to eq(["Integer"])
        patch = "class Object\n  def ==(other) = true\nend\n"
        expect(dumped_types(run_case_eq("Integer?", "expect(x).to eq(9)\ndump_type(x)\n", patch: patch)))
          .to eq(["9?"])
      end

      it "gives no fact when a reopened core ancestor up to the owner defines the literal's operator" do
        patch = "class Object\n  def eql?(other) = true\nend\n"
        expect(dumped_types(run_case_eq("Symbol", "expect(x).to eql(:s)\ndump_type(x)\n", patch: patch)))
          .to eq(["Symbol"])
      end

      it "narrows an Integer local to the literal after eq(9)" do
        result = run_plugin(source: "x = rand(10)\nexpect(x).to eq(9)\ndump_type(x)\n")
        expect(dumped_types(result)).to eq(["9"])
      end

      it "keeps the local's type when the project defines == on the literal's class" do
        result = run_plugin(
          source: <<~RUBY
            class Integer
              def ==(other) = true
            end

            x = rand(10)
            expect(x).to eq(9)
            dump_type(x)
          RUBY
        )
        expect(dumped_types(result)).not_to include("9")
      end

      # Guard: pins the engine's handling of the negative Constant fact, which predates #1807 and survives a revert
      # of the fix.
      it "leaves the local unchanged after not_to eq(literal)" do
        result = run_plugin(source: "x = rand(10)\ndump_type(x)\nexpect(x).not_to eq(9)\ndump_type(x)\n")
        before, after = dumped_types(result)
        expect(after).to eq(before)
      end

      # Guards of existing behaviour, added with the rigor-rspec manual's matcher table. Each one passes with the
      # current code; none has a fix whose removal it would catch, so the mutation table records no line for them.
      it "meets the local with the class for be_a, be_kind_of, be_instance_of and be_an_instance_of" do
        expect(dumped_types(run_case_eq("Integer?", "expect(x).to be_a(Numeric)\ndump_type(x)\n"))).to eq(["Integer"])
        expect(dumped_types(run_case_eq("Integer?", "expect(x).to be_kind_of(Numeric)\ndump_type(x)\n")))
          .to eq(["Integer"])
        expect(dumped_types(run_case_eq("Integer?", "expect(x).to be_instance_of(Integer)\ndump_type(x)\n")))
          .to eq(["Integer"])
        expect(dumped_types(run_case_eq("Integer?", "expect(x).to be_an_instance_of(Integer)\ndump_type(x)\n")))
          .to eq(["Integer"])
      end

      it "narrows the local away from nil after not_to be_nil and to_not be_nil" do
        expect(dumped_types(run_case_eq("Integer?", "expect(x).not_to be_nil\ndump_type(x)\n"))).to eq(["Integer"])
        expect(dumped_types(run_case_eq("Integer?", "expect(x).to_not be_nil\ndump_type(x)\n"))).to eq(["Integer"])
      end

      it "narrows the local away from T after not_to be_a(T), and leaves it when T is not a member" do
        expect(dumped_types(run_case_eq("Integer?", "expect(x).not_to be_kind_of(Integer)\ndump_type(x)\n")))
          .to eq(["nil"])
        expect(dumped_types(run_case_eq("Integer?", "expect(x).not_to be_instance_of(Integer)\ndump_type(x)\n")))
          .to eq(["nil"])
        expect(dumped_types(run_case_eq("Integer?", "expect(x).not_to be_an_instance_of(Integer)\ndump_type(x)\n")))
          .to eq(["nil"])
        expect(dumped_types(run_case_eq("Integer?", "expect(x).not_to be_a(String)\ndump_type(x)\n")))
          .to eq(["Integer?"])
      end

      it "keeps the whole local when a member is outside the core equality classes" do
        source = "k = rand(2).zero? ? [1] : 9\ndump_type(k)\nexpect(k).to eq(9)\ndump_type(k)\n"
        expect(dumped_types(run_plugin(source: source))).to eq(["9 | [1]", "9 | [1]"])
        source = "k = rand(2).zero? ? { a: 1 } : 9\ndump_type(k)\nexpect(k).to eq(9)\ndump_type(k)\n"
        expect(dumped_types(run_plugin(source: source))).to eq(["9 | { a: 1 }", "9 | { a: 1 }"])
      end

      it "keeps Complex as a numeric member under eq, as it keeps Float and Rational" do
        expect(dumped_types(run_case_eq("Integer | Complex", "expect(x).to eq(1)\ndump_type(x)\n")))
          .to eq(["1 | Complex"])
      end

      it "leaves the local unchanged after not_to eql(literal) and to_not eql(literal)" do
        result = run_plugin(source: "x = rand(10)\ndump_type(x)\nexpect(x).not_to eql(9)\ndump_type(x)\n")
        before, after = dumped_types(result)
        expect(after).to eq(before)
        result = run_plugin(source: "x = rand(10)\ndump_type(x)\nexpect(x).to_not eql(9)\ndump_type(x)\n")
        before, after = dumped_types(result)
        expect(after).to eq(before)
      end

      it "keeps the local's type when the project defines eql? on the literal's class" do
        patch = "class Integer\n  def eql?(other) = true\nend\n"
        expect(dumped_types(run_case_eq("Integer", "expect(x).to eql(9)\ndump_type(x)\n", patch: patch)))
          .to eq(["Integer"])
      end
    end
  end

  # Pillar 2 Slice 2 — let / subject locals in `it` bodies are bound to their inferred return type. Tests
  # exercise the LetScopeIndex + LetTypeResolver directly with a stub factory_index where applicable; the
  # end-to-end run goes through `dynamic_return` to prove the engine actually narrows the local.
  describe "let / subject binding (Pillar 2 Slice 2)" do
    describe "LetScopeIndex" do
      def build_index(source)
        Rigor::Plugin::Rspec::LetScopeIndex.build(Prism.parse(source).value)
      end

      it "records the describe-const anchor for `RSpec.describe SomeModel do`" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            let(:user) { 1 }
          end
        RUBY
        expect(index.records.size).to eq(1)
        expect(index.records.first.describe_const).to eq("User")
        expect(index.records.first.lets.keys).to contain_exactly(:user)
      end

      it "records nested describe scopes with inherited const" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            let(:user) { 1 }
            describe ".active" do
              let(:filter) { 2 }
            end
          end
        RUBY
        # Two records: outer (User, lets [:user]) and inner (anchor inherits User, lets [:filter]).
        expect(index.records.size).to eq(2)
        const_anchors = index.records.map(&:describe_const)
        expect(const_anchors).to eq(%w[User User])
      end

      it "resolves let_block_at by walking innermost to outermost" do
        source = <<~RUBY
          RSpec.describe User do
            let(:name) { "outer" }
            describe "inner" do
              let(:name) { "inner" }
              it "x" do
                name
              end
            end
          end
        RUBY
        index = build_index(source)
        # The `name` read inside the inner `it` block is line 6; the inner-record's `:name` let wins.
        block = index.let_block_at(6, :name)
        expect(block).not_to be_nil
        expect(block.body.body.first.unescaped).to eq("inner")
      end

      it "captures the implicit `subject { ... }` under :subject" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            subject { User.new }
          end
        RUBY
        expect(index.records.first.lets.keys).to contain_exactly(:subject)
      end

      it "captures the named `subject(:user) { ... }` under :user" do
        index = build_index(<<~RUBY)
          RSpec.describe User do
            subject(:user) { User.new }
          end
        RUBY
        expect(index.records.first.lets.keys).to contain_exactly(:user)
      end
    end

    describe "LetTypeResolver" do
      def block_node(source)
        ast = Prism.parse(source).value
        ast.statements.body.first.block
      end

      it "resolves `let(:user) { User.new }` to Nominal[User]" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { User.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end

      it "resolves `let(:doc) { Foo::Bar.new }` to Nominal[Foo::Bar]" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:doc) { Foo::Bar.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Foo::Bar"))
      end

      it "resolves `subject { described_class.new }` via the enclosing describe_const" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("subject { described_class.new }"),
          describe_const: "User", factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end

      it "returns nil for `described_class.new` without an anchor" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("subject { described_class.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to be_nil
      end

      it "resolves `let(:user) { create(:user) }` via factory_index.model_class" do
        factory_index = Class.new do
          def find(name)
            return nil unless name == "user"

            Struct.new(:model_class).new("User")
          end
        end.new
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { create(:user) }"),
          describe_const: nil, factory_index: factory_index, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end

      it "resolves `let(:user) { FactoryBot.build_stubbed(:user) }`" do
        factory_index = Class.new do
          def find(name) = name == "user" ? Struct.new(:model_class).new("Admin::User") : nil
        end.new
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { FactoryBot.build_stubbed(:user) }"),
          describe_const: nil, factory_index: factory_index, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("Admin::User"))
      end

      it "returns nil for unrecognised body shapes" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { some_helper_method }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to be_nil
      end

      it "returns nil for factorybot calls when factory_index is missing" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { create(:user) }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to be_nil
      end

      it "uses the LAST statement of a multi-stmt block body" do
        type = Rigor::Plugin::Rspec::LetTypeResolver.resolve(
          block_node("let(:user) { x = 1\nUser.new }"),
          describe_const: nil, factory_index: nil, environment: nil
        )
        expect(type).to eq(Rigor::Type::Combinator.nominal_of("User"))
      end
    end

    describe "end-to-end through the engine" do
      it "binds `user` inside an `it` body to Nominal[User] via let(:user) { User.new }" do
        result = run_plugin(
          source: <<~RUBY
            RSpec.describe User do
              let(:user) { User.new }
              it "test" do
                expect(user).to be_a(User)
              end
            end
          RUBY
        )
        # No undefined-method diagnostics — `user` resolved through the let binding rather than as an unknown
        # method call. The engine's matcher narrowing (Slice 1) plus the let binding (Slice 2) compose cleanly.
        undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
        expect(undefined).to be_empty
      end
    end
  end

  describe "edge cases" do
    it "ignores files with no `RSpec.describe` block" do
      result = run_plugin(source: "x = 1\nputs x\n")
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "ignores `let` calls outside an RSpec describe block" do
      result = run_plugin(
        source: <<~RUBY
          # Not an RSpec file — just calls `let` at top level.
          let(:user) { :first }
          let(:user) { :second }
        RUBY
      )
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "handles `subject` with no name (the implicit subject)" do
      # Two `subject { ... }` calls at the same scope are still duplicates of the implicit `:subject`.
      result = run_plugin(
        source: <<~RUBY
          RSpec.describe "X" do
            subject { :first }
            subject { :second }
          end
        RUBY
      )
      err = plugin_diagnostics(result).find { |d| d.rule == "duplicate-let" }
      expect(err).not_to be_nil
      expect(err.message).to include("subject(:subject)")
    end
  end
end
