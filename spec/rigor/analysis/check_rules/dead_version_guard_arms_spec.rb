# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "rigor/inference/version_guard"

# ADR-47 WD5 / issue #627 — the dead arm of a decidable version guard is unreachable on the Ruby the user
# is checking with, so nothing inside it reports and its writes do not join into the post-`if` scope.
#
# Two halves are under test together, because either one alone leaves the false positive standing:
# {Rigor::Inference::StatementEvaluator}'s arm elision (the scope half) and
# {Rigor::Analysis::CheckRules::DeadVersionGuardArms} (the diagnostic half — the rule walk visits every
# node whether or not the evaluator typed it).
RSpec.describe "dead version-guard arms" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def arity_diagnostics(source)
    diagnostics_for(source).select { |d| d.rule == "call.wrong-arity" }
  end

  def verdict_for(predicate_source)
    node = Prism.parse("if #{predicate_source}\n1\nend\n").value.statements.body.first
    Rigor::Inference::VersionGuard.verdict(node.predicate)
  end

  # `mail/lib/mail/yaml.rb:26` verbatim in shape: the `else` is Psych's pre-3.1 positional `safe_load`,
  # honest against that Psych and dead against the one shipped with the Ruby running rigor.
  describe "the mail repro (#627)" do
    let(:source) do
      <<~RUBY
        require "yaml"
        def load(yaml, permitted_classes)
          if Gem::Version.new(Psych::VERSION) >= Gem::Version.new("3.1.0.pre1")
            ::YAML.safe_load(yaml, permitted_classes: permitted_classes)
          else
            ::YAML.safe_load(yaml, permitted_classes)
          end
        end
      RUBY
    end

    # must-not-fire
    it "does not report the arity of the dead pre-3.1 arm" do
      expect(arity_diagnostics(source)).to be_empty
    end

    # discrimination — flipping the comparison moves the live arm, and the SAME call now reports
    it "reports that very call once the comparison is flipped and the arm goes live" do
      flipped = source.sub(">= Gem::Version", "< Gem::Version")
      diags = arity_diagnostics(flipped)
      expect(diags.size).to eq(1)
      expect(diags.first.line).to eq(6)
      expect(diags.first.method_name).to eq("safe_load")
    end
  end

  describe "RUBY_VERSION guards" do
    # must-fire — the LIVE arm is checked exactly as before
    it "still reports a wrong arity in the live arm" do
      diags = arity_diagnostics(<<~RUBY)
        require "yaml"
        def load(yaml, permitted)
          if RUBY_VERSION >= "3.1"
            ::YAML.safe_load(yaml, permitted)
          else
            ::YAML.safe_load(yaml)
          end
        end
      RUBY
      expect(diags.size).to eq(1)
      expect(diags.first.line).to eq(4)
    end

    # must-not-fire
    it "silences the dead arm of the same guard" do
      expect(arity_diagnostics(<<~RUBY)).to be_empty
        require "yaml"
        def load(yaml, permitted)
          if RUBY_VERSION >= "3.1"
            ::YAML.safe_load(yaml)
          else
            ::YAML.safe_load(yaml, permitted)
          end
        end
      RUBY
    end

    # must-fire — an unreadable operand keeps BOTH arms live, which is the pre-existing behaviour
    it "keeps both arms live when one side of the comparison is not readable" do
      diags = arity_diagnostics(<<~RUBY)
        require "yaml"
        def load(yaml, permitted, threshold)
          if threshold >= "3.1"
            ::YAML.safe_load(yaml, permitted)
          else
            ::YAML.safe_load(yaml, permitted)
          end
        end
      RUBY
      expect(diags.map(&:line)).to eq([4, 6])
    end

    # `unless` runs its body on the falsey edge, so its arms are the mirror image
    it "silences the dead body of an `unless` guard" do
      expect(arity_diagnostics(<<~RUBY)).to be_empty
        require "yaml"
        def load(yaml, permitted)
          unless RUBY_VERSION >= "3.1"
            ::YAML.safe_load(yaml, permitted)
          end
        end
      RUBY
    end

    # the guard itself is intentional, not a redundant condition
    it "does not report flow.always-truthy-condition on the guard" do
      flow = diagnostics_for(<<~RUBY).select { |d| d.rule.to_s.start_with?("flow.") }
        if RUBY_VERSION >= "3.1"
          1
        else
          2
        end
      RUBY
      expect(flow).to be_empty
    end
  end

  describe "the post-`if` scope" do
    def dump_types(source)
      diagnostics_for(source).select { |d| d.rule == "dump.type" }.map(&:message)
    end

    # the dead arm's writes must not join — mirrors what `if false` does
    it "carries only the live arm's binding past the guard" do
      expect(dump_types(<<~RUBY)).to eq(["dump_type: 1"])
        if RUBY_VERSION >= "3.1"
          v = 1
        else
          v = "s"
        end
        Rigor.dump_type(v)
      RUBY
    end

    # must-still-succeed sibling: an undecidable guard still joins both arms
    it "still joins both arms when the guard is undecidable" do
      expect(dump_types(<<~RUBY)).to eq(['dump_type: "s" | 1'])
        def pick(threshold)
          if threshold >= "3.1"
            v = 1
          else
            v = "s"
          end
          Rigor.dump_type(v)
        end
      RUBY
    end
  end

  # `ExpressionTyper` types an `if` reached through `type_of` (the expression-position ternary among them)
  # on its own path, so it has to read the same verdict or the two typers disagree about which arm survives.
  describe "the ExpressionTyper path" do
    def expression_type(source)
      Rigor::Scope.empty.type_of(Prism.parse(source).value.statements.body.first).describe
    end

    it "elides the dead arm of a ternary version guard" do
      expect(expression_type('RUBY_VERSION >= "3.1" ? 1 : "s"')).to eq("1")
      expect(expression_type('RUBY_VERSION < "3.1" ? 1 : "s"')).to eq('"s"')
    end

    it "still unions both arms of an undecidable ternary" do
      expect(expression_type('x ? 1 : "s"')).to eq('"s" | 1')
    end
  end

  describe Rigor::Inference::VersionGuard do
    it "decides RUBY_VERSION against a literal" do
      expect(verdict_for('RUBY_VERSION >= "0.0"')).to eq(:truthy)
      expect(verdict_for('RUBY_VERSION >= "99.0"')).to eq(:falsey)
    end

    it "decides RUBY_ENGINE equality, and declines an ordering comparison on it" do
      expect(verdict_for('RUBY_ENGINE == "jruby"')).to eq(:falsey)
      expect(verdict_for('RUBY_ENGINE != "jruby"')).to eq(:truthy)
      expect(verdict_for('RUBY_ENGINE > "jruby"')).to be_nil
    end

    # The two spellings genuinely disagree, and each must answer with its own semantics: `"4.0.5" > "4.0.05"`
    # is true (Ruby compares strings lexically — that is what runs), while the two `Gem::Version`s are equal.
    # Built from the running RUBY_VERSION so the pair holds on any Ruby.
    it "uses String semantics for a bare comparison and Gem::Version semantics for a wrapped one" do
      padded = RUBY_VERSION.sub(/(\d+)\z/) { "0#{Regexp.last_match(1)}" }
      expect(verdict_for(%(RUBY_VERSION > "#{padded}"))).to eq(:truthy)
      expect(verdict_for(%(Gem::Version.new(RUBY_VERSION) > Gem::Version.new("#{padded}")))).to eq(:falsey)
    end

    it "declines the shapes outside the envelope" do
      expect(verdict_for('RUBY_VERSION <=> "3.1"')).to be_nil
      expect(verdict_for('RUBY_PLATFORM == "java"')).to be_nil
      expect(verdict_for('Gem::Version.new(RUBY_VERSION) >= "3.1"')).to be_nil
      expect(verdict_for('Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("not a version")')).to be_nil
      expect(verdict_for('"3.9" >= "3.10"')).to be_nil
      expect(verdict_for('Foo::VERSION >= "3.1"')).to be_nil
      expect(verdict_for("defined?(Ractor)")).to be_nil
    end
  end
end
