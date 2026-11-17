# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `StatementEvaluator::PatternBindings` binds the names a `rescue` reference, a `case/in` pattern, a
# one-line `in` / `=>` match and a named-capture `=~` introduce. The examples call its entries directly with a real
# evaluator (the module calls back `sub_eval`, `widen_index_target` and `widen_attribute_write` on it) over a scope
# from `Scope.empty`, and read the bound names off the returned scope. `statement_evaluator_spec.rb` pins the same
# behaviour through the whole walk.
#
# One guard no example distinguishes: `eval_match_write`'s `next s unless target.is_a?(LocalVariableTargetNode)`. Every
# `MatchWriteNode` target is a local-variable target; tried an underscore name, a name that is already a local, a
# method's name (`puts`), an interpolated or `o`-flag regexp, and a modifier or `if` position, and Prism answers
# `LocalVariableTargetNode` for each.
RSpec.describe Rigor::Inference::StatementEvaluator::PatternBindings do
  let(:combinator) { Rigor::Type::Combinator }
  let(:scope) { Rigor::Scope.empty }
  let(:evaluator) { Rigor::Inference::StatementEvaluator.new(scope: scope) }
  let(:integer) { combinator.nominal_of("Integer") }
  let(:string) { combinator.nominal_of("String") }
  # The evaluator's side of the interface: records the callbacks the module makes and answers with canned values.
  let(:marker) { scope.with_local(:marker, const(1)) }
  let(:recorder_class) do
    Struct.new(:calls, :marker, :sub_eval_type) do
      def sub_eval(node, with_scope)
        calls << [:sub_eval, [node, with_scope]]
        [sub_eval_type, with_scope]
      end

      def widen_index_target(target, stored, current_scope, type_scope:)
        calls << [:widen_index_target, [target, stored, current_scope, type_scope]]
        marker
      end

      def widen_attribute_write(receiver, writer, current_scope)
        calls << [:widen_attribute_write, [receiver, writer, current_scope]]
        marker
      end
    end
  end

  def const(value) = combinator.constant_of(value)

  def recorder(sub_eval_type: combinator.untyped) = recorder_class.new([], marker, sub_eval_type)

  def evaluate(source, base_scope: scope) = base_scope.evaluate(Prism.parse(source).value)

  def rescue_clause(source) = Prism.parse(source).value.statements.body.first.rescue_clause

  def bind_reference(source, start = scope)
    described_class.bind_rescue_reference(rescue_clause(source), start, evaluator)
  end

  # `[subject_node, pattern]` of the first `in` branch of `source`'s `case`.
  def first_in(source)
    node = Prism.parse(source).value.statements.body.first
    [node.predicate, node.conditions.first.pattern]
  end

  def bind_in(subject_type, source, start = scope)
    subject, pattern = first_in(source)
    described_class.apply_in_pattern_bindings(subject_type, subject, pattern, start, evaluator)
  end

  describe ".bind_rescue_reference" do
    it "binds a local reference to the union of the named classes' instances" do
      bound = bind_reference("begin; 1; rescue ArgumentError, TypeError => e; end")

      expect(bound.local(:e)).to eq(combinator.union(combinator.nominal_of("ArgumentError"),
                                                     combinator.nominal_of("TypeError")))
    end

    it "binds a bare `rescue` to StandardError" do
      expect(bind_reference("begin; 1; rescue => e; end").local(:e)).to eq(combinator.nominal_of("StandardError"))
    end

    it "types a class the scope evaluates through the evaluator, as Dynamic[top] when it is not a class object" do
      bound = bind_reference("begin; 1; rescue unknown_name => e; end")

      expect(bound.local(:e)).to eq(combinator.untyped)
    end

    it "binds an instance, global and class variable reference to the exception type" do
      expect(bind_reference("begin; 1; rescue IOError => @io; end").ivar(:@io)).to eq(combinator.nominal_of("IOError"))
      expect(bind_reference("begin; 1; rescue IOError => $out; end").global(:$out))
        .to eq(combinator.nominal_of("IOError"))
      expect(bind_reference("begin; 1; rescue IOError => @@out; end").cvar(:@@out))
        .to eq(combinator.nominal_of("IOError"))
    end

    it "ends a class guard's narrowing of the instance variable it writes" do
      guarded = scope.with_guarded_ivar(:@io, string, integer)

      expect(guarded.guard_narrowed_ivar?(:@io)).to be(true)
      expect(bind_reference("begin; 1; rescue IOError => @io; end", guarded).guard_narrowed_ivar?(:@io)).to be(false)
    end

    it "binds no local for a reference-less clause and leaves the scope's locals alone" do
      start = scope.with_local(:z, integer)

      bound = bind_reference("begin; 1; rescue IOError; end", start)

      expect(bound.local(:z)).to eq(integer)
      expect(bound.global(:$!)).to eq(combinator.nominal_of("IOError"))
    end

    it "hands an index-target reference to the evaluator's widen_index_target with the exception as the stored value" do
      host = recorder(sub_eval_type: combinator.singleton_of("IOError"))
      clause = rescue_clause("begin; 1; rescue IOError => h[:e]; end")

      result = described_class.bind_rescue_reference(clause, scope, host)

      expect(host.calls.map(&:first)).to eq(%i[sub_eval widen_index_target])
      target, stored, current, type_scope = host.calls.last.last
      expect(target).to equal(clause.reference)
      expect(stored).to eq(combinator.nominal_of("IOError"))
      expect(current).to equal(type_scope)
      expect(result).to equal(marker)
    end

    it "hands an attribute-target reference to the evaluator's widen_attribute_write" do
      host = recorder
      clause = rescue_clause("begin; 1; rescue IOError => w.r; end")

      result = described_class.bind_rescue_reference(clause, scope.with_local(:z, integer), host)

      expect(host.calls.map(&:first)).to eq(%i[sub_eval widen_attribute_write])
      receiver, writer, current = host.calls.last.last
      expect([receiver, writer]).to eq([clause.reference.receiver, clause.reference.name])
      expect(current.local(:z)).to eq(integer)
      expect(result).to equal(marker)
    end

    it "types each named class through the evaluator's sub_eval" do
      host = recorder(sub_eval_type: combinator.singleton_of("IOError"))

      bound = described_class.bind_rescue_reference(rescue_clause("begin; 1; rescue Whatever => e; end"), scope,
                                                    host)

      expect(host.calls.map(&:first)).to eq([:sub_eval])
      expect(bound.local(:e)).to eq(combinator.nominal_of("IOError"))
    end
  end

  describe ".apply_in_pattern_bindings" do
    it "binds each capture of an array pattern against the subject's tuple slots" do
      subject_type = combinator.tuple_of(integer, string)

      bound = bind_in(subject_type, "case v\nin [a, b]\nend")

      expect([bound.local(:a), bound.local(:b)]).to eq([integer, string])
    end

    it "floors every name to Dynamic[top] when the case carries no subject type" do
      bound = bind_in(nil, "case v\nin [a, b]\nend")

      expect([bound.local(:a), bound.local(:b)]).to all(eq(combinator.untyped))
    end

    it "binds a class capture to the class's instances even over an untyped subject" do
      bound = bind_in(nil, "case v\nin Integer => n\nend")

      expect(bound.local(:n)).to eq(integer)
    end

    it "binds a value capture to the literal's own type" do
      expect(bind_in(nil, "case v\nin 1 => n\nend").local(:n)).to eq(const(1))
    end

    it "binds hash-pattern keys against a hash shape's values" do
      shape = combinator.hash_shape_of({ k: integer, s: string })

      bound = bind_in(shape, "case v\nin { k:, s: String => t }\nend")

      expect([bound.local(:k), bound.local(:t)]).to eq([integer, string])
    end

    it "binds the rest of a splatted array pattern to an Array of the leftover element types" do
      subject_type = combinator.nominal_of("Array", type_args: [integer])

      bound = bind_in(subject_type, "case v\nin [first, *rest]\nend")

      expect(bound.local(:rest)).to eq(combinator.nominal_of("Array", type_args: [integer]))
    end

    it "keeps only the names every alternative of a union subject binds precisely" do
      subject_type = combinator.union(combinator.tuple_of(integer), combinator.tuple_of(string))

      bound = bind_in(subject_type, "case v\nin [a]\nend")

      expect(bound.local(:a)).to eq(combinator.union(integer, string))
    end

    it "floors a name to Dynamic[top] when one member of a union leaves it untyped" do
      subject_type = combinator.union(combinator.tuple_of(integer), combinator.nominal_of("Object"))

      bound = bind_in(subject_type, "case v\nin [a]\nend")

      expect(bound.local(:a)).to eq(combinator.untyped)
    end

    it "marks a class capture over a Dynamic subject as a gradual narrowing" do
      start = scope.with_local(:v, combinator.untyped)

      bound = bind_in(combinator.untyped, "case v\nin Integer => n\nend", start)

      expect(bound.gradual_narrowing?(:n)).to be(true)
    end

    it "does not mark a capture of a non-class pattern" do
      start = scope.with_local(:v, combinator.untyped)

      expect(bind_in(combinator.untyped, "case v\nin 1 => n\nend", start).gradual_narrowing?(:n)).to be(false)
    end
  end

  describe ".eval_match_pattern" do
    it "binds the captures of `value => pattern` into the post-scope and evaluates to nil" do
      _, post = evaluate("v = [1, 'a']\nv => [a, b]")

      expect([post.local(:a), post.local(:b)]).to eq([const(1), const("a")])
    end

    it "binds the captures of `value in pattern` and answers a boolean" do
      type, post = evaluate("h = { k: 1 }\nh in { k: Integer => t }")

      expect(post.local(:t)).to eq(integer)
      expect(type).to eq(combinator.nominal_of("bool")).or eq(combinator.union(const(true), const(false)))
    end

    it "evaluates the subject in the scope it is handed and binds into the scope that evaluation answers" do
      host = recorder(sub_eval_type: combinator.tuple_of(integer, string))
      node = Prism.parse("v => [a, b]").value.statements.body.first

      _type, bound = described_class.eval_match_pattern(node, scope, nil, host)

      expect(host.calls).to eq([[:sub_eval, [node.value, scope]]])
      expect([bound.local(:a), bound.local(:b)]).to eq([integer, string])
    end
  end

  describe ".eval_match_write" do
    it "binds each named capture of a regexp match to String | nil" do
      _, post = evaluate("/(?<year>\\d+)-(?<mon>\\d+)/ =~ 'x'")

      expected = combinator.union(string, const(nil))
      expect([post.local(:year), post.local(:mon)]).to eq([expected, expected])
    end

    it "binds only local-variable targets" do
      node = Prism.parse("/(?<year>\\d+)/ =~ 'x'").value.statements.body.first

      _type, bound = described_class.eval_match_write(node, scope, evaluator)

      expect(bound.local(:year)).to eq(combinator.union(string, const(nil)))
    end
  end
end
