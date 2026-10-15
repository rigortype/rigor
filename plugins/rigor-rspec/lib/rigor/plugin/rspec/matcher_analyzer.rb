# frozen_string_literal: true

require "prism"
require "rigor/type"
require "rigor/flow_contribution"
require "rigor/flow_contribution/fact"

module Rigor
  module Plugin
    class Rspec < Rigor::Plugin::Base
      # Recognises `expect(x).to MATCHER` patterns at per-call recognition time and emits
      # `post_return_facts` that narrow the named local on the post-call edge.
      #
      # The supported matchers are the lowest-false-positive floor of the RSpec matcher DSL:
      #
      # - `be_a(T)` / `be_kind_of(T)` — `x is_a?(T)` style class membership; narrows `x` to `T`.
      # - `be_instance_of(T)` — exact-class match; narrows `x` to `T` (the engine currently treats
      #   Nominal[T] uniformly, so the distinction with `be_a` is observed at the carrier level but not the
      #   runtime).
      # - `be_nil` — narrows `x` to `Constant<nil>`.
      # - `eq(LITERAL)` / `eql(LITERAL)` for a literal-value argument — meets `x` with `Constant<literal>`
      #   (see "Equality is the local's own method" below).
      #
      # The matchers below this floor (`be_truthy` / `be_falsey` / `be_within` / `be > / < / >=` /
      # `include` / `start_with` / `match(regex)` / `raise_error` / receive-style mocks) require either
      # edge-aware fragments (`truthy_facts` / `falsey_facts` rather than `post_return_facts`) or
      # diagnostic-only enforcement; both are queued for follow-up slices.
      #
      # The analyzer fires ONLY when:
      #
      # 1. The call node is one of `<recv>.to(matcher)` / `<recv>.not_to(matcher)` /
      #    `<recv>.to_not(matcher)`. `not_to` / `to_not` flip the fact's `negative` flag so the engine
      #    narrows AWAY from the matcher's type (e.g. `not_to be_nil` removes nil from the receiver).
      # 2. The receiver is `expect(<local_var>)` — exactly one positional argument that's a
      #    LocalVariableReadNode. Composite receivers (`expect(foo.bar)`, `expect { ... }.to raise_error`)
      #    fall through.
      # 3. The matcher is one of the recognised forms above (`be_a` / `be_kind_of` / `be_instance_of` /
      #    `be_an_instance_of` / `be_nil` / `eq(literal)` / `eql(literal)` / `match(/regex/)`).
      #
      # ## Equality is the local's own method
      #
      # `expect(x).to eq(lit)` passes when `x == lit` and `eql(lit)` when `x.eql?(lit)`: the local is the
      # receiver, so its own `==` / `eql?` decides, and a class with a custom `==` can equal even a `nil`,
      # boolean or Symbol literal. A positive equality fact therefore never replaces the local's type (issue
      # #1807). It is a meet with the local's current type, member by member:
      #
      # - a member of the literal's own core class (`Integer`, `Float`, `String`, `Symbol`, `NilClass`,
      #   `TrueClass`, `FalseClass`) narrows to the literal, a refinement of that class (`non-empty-string`,
      #   `decimal-int-string`, `non-zero-int`) included; a `Constant` member is kept when it equals the
      #   literal and dropped otherwise; a `Float` member meeting `0.0` (which `-0.0` also equals) is kept;
      # - a core numeric member of another class (`Integer`, `Float`, `Rational`, `Complex`) is kept under
      #   `eq` (`1.0 == 1`) and dropped under `eql` (`1.0.eql?(1)` is false);
      # - any other core member (`nil` against `9`, a `String` against `:a`) is dropped: built-in equality
      #   across those classes is false;
      # - a member of a core class is kept unnarrowed when the project's source defines the operator on that
      #   class or on a core ancestor up to the one that owns the operator at runtime (`class Symbol; def
      #   ==`, `class Numeric; def eql?` for an `Integer`, `class Object; def ==` for `nil`): its own method
      #   decides.
      #
      # When any member is `Dynamic` or of any other class (a user class, `Object`, `Numeric`, `BigDecimal`),
      # the analyzer emits no fact and the local keeps its type. It also emits none when the project's source
      # defines the operator on the literal's class or those ancestors of it — a core `==` calls back into the
      # literal's (`Integer#==` runs `other == self` for a non-numeric argument, `String#==` for one that
      # responds to `to_str`), so a custom one there can make any member equal — and for an unbound local,
      # when no member survives, and without a scope. A reopening that defines other methods only
      # (`class String; def shout`) does not count.
      #
      # The negative forms (`not_to` / `to_not`) still emit a negative `Constant` fact, which the engine's fact
      # narrowing does not act on, so the local keeps its type there too.
      module MatcherAnalyzer
        module_function

        # @param call_node — the call whose contribution we're computing. Returns nil when
        #   the call shape does not match `expect(local).to matcher`.
        # @param scope — the scope at the call, or nil. Its environment resolves a matcher's class-name
        #   argument to a `Type::Nominal` (without one, a bare `Nominal[<name>]` carrier — sound, the receiver
        #   constant may be a user class not in RBS); the local's current type in it is what a positive
        #   `eq` / `eql` fact meets (without one, no such fact).
        def contribution_for(call_node, scope:)
          verb = assertion_verb(call_node)
          return nil if verb.nil?
          return nil unless call_node.receiver.is_a?(Prism::CallNode)

          expect_call = call_node.receiver
          return nil unless expect_call?(expect_call)

          target_local = expect_first_arg_local(expect_call)
          return nil if target_local.nil?

          matcher = matcher_call(call_node)
          return nil if matcher.nil?

          negative = verb == :negative
          narrowed_type = narrowed_type_for(matcher, target_local, negative: negative, scope: scope)
          return nil if narrowed_type.nil?

          fact = Rigor::FlowContribution::Fact.new(
            target_kind: :local,
            target_name: target_local,
            type: narrowed_type,
            negative: negative
          )
          Rigor::FlowContribution.new(post_return_facts: [fact])
        end

        # Recognises the assertion verb chained after `expect(...)`:
        # - `.to(<matcher>)`     → :positive
        # - `.not_to(<matcher>)` → :negative
        # - `.to_not(<matcher>)` → :negative (older spelling)
        # Returns nil for any other call.
        def assertion_verb(node)
          return nil unless node.is_a?(Prism::CallNode)
          return nil unless node.arguments&.arguments&.size == 1

          case node.name
          when :to then :positive
          when :not_to, :to_not then :negative
          end
        end

        def expect_call?(node)
          node.is_a?(Prism::CallNode) && node.name == :expect &&
            node.receiver.nil? && node.arguments&.arguments&.size == 1
        end

        def expect_first_arg_local(expect_call)
          arg = expect_call.arguments.arguments.first
          return nil unless arg.is_a?(Prism::LocalVariableReadNode)

          arg.name
        end

        def matcher_call(to_call)
          to_call.arguments.arguments.first
        end

        # Translates a recognised matcher CallNode into the
        # narrowed type. Returns nil when the matcher is
        # unrecognised or its argument shape does not match the
        # supported envelope.
        def narrowed_type_for(matcher, target_local, negative:, scope:)
          environment = scope&.environment
          return nil unless matcher.is_a?(Prism::CallNode) && matcher.receiver.nil?

          case matcher.name
          when :be_a, :be_kind_of, :be_instance_of, :be_an_instance_of
            nominal_type_for_class_arg(matcher, environment: environment)
          when :be_nil
            return nil unless empty_args?(matcher)

            Rigor::Type::Combinator.constant_of(nil)
          when :eq, :eql
            equality_type_for_literal_arg(matcher, target_local, negative: negative, scope: scope)
          when :match
            # `match(/regex/)` narrows x to String. `match("...")` or `match(arbitrary_object)` falls
            # through — the broader matcher dispatch needs the receiver to be a String, but we can only
            # assert that for a literal regex.
            string_type_for_regex_arg(matcher)
          end
        end

        def nominal_type_for_class_arg(matcher, environment:)
          args = matcher.arguments&.arguments || []
          return nil unless args.size == 1

          class_name = constant_path_name(args.first)
          return nil if class_name.nil?

          if environment
            environment.nominal_for_name(class_name) ||
              Rigor::Type::Combinator.nominal_of(class_name)
          else
            Rigor::Type::Combinator.nominal_of(class_name)
          end
        end

        def equality_type_for_literal_arg(matcher, target_local, negative:, scope:)
          args = matcher.arguments&.arguments || []
          return nil unless args.size == 1

          literal_value = literal_value_for(args.first)
          return nil if literal_value.equal?(NO_LITERAL)
          return Rigor::Type::Combinator.constant_of(literal_value) if negative
          return nil if scope.nil?

          operator = matcher.name == :eql ? :eql? : :==
          equality_meet(scope.local(target_local), literal_value, operator, scope)
        end

        # --- equality meet (`eq` / `eql`; see "Equality is the local's own method") ---

        # Core classes whose `==` / `eql?` Rigor can evaluate against a literal: across any two of them the
        # answer is built in, unless the project defines the operator on one of them.
        EQUALITY_CORE_CLASSES = [Integer, Float, Rational, Complex, String, Symbol, NilClass, TrueClass,
                                 FalseClass].freeze
        Ractor.make_shareable(EQUALITY_CORE_CLASSES)
        private_constant :EQUALITY_CORE_CLASSES

        NUMERIC_CLASS_NAMES = %w[Integer Float Rational Complex].freeze
        Ractor.make_shareable(NUMERIC_CLASS_NAMES)
        private_constant :NUMERIC_CLASS_NAMES

        # For each core class and operator, the class and its ancestors up to and including the one that owns
        # the operator at runtime (`Integer#eql?` is `Numeric`'s, `nil == x` is `BasicObject`'s). A project
        # definition on any of them is the method the member runs; one above the owner is shadowed by it.
        OPERATOR_OWNER_CHAINS = EQUALITY_CORE_CLASSES.each_with_object({}) do |klass, chains|
          %i[== eql?].each do |operator|
            ancestors = klass.ancestors
            owner_index = ancestors.index(klass.instance_method(operator).owner)
            chains[[klass.name, operator]] = ancestors[0..owner_index].map(&:name).freeze
          end
        end.freeze
        Ractor.make_shareable(OPERATOR_OWNER_CHAINS)
        private_constant :OPERATOR_OWNER_CHAINS

        # Marks a member whose equality with the literal cannot be decided, so the whole meet gives up.
        UNDECIDED = Object.new.freeze
        private_constant :UNDECIDED

        # The members of `current` that `x <operator> literal` admits, narrowed where the member's class is
        # the literal's, or nil when any member is undecided or none survives. An unbound local (nil) is one
        # undecided member.
        def equality_meet(current, literal, operator, scope)
          return nil if project_defines?(literal.class.name, operator, scope)

          members = current.is_a?(Rigor::Type::Union) ? current.members : [current]
          kept = []
          members.each do |member|
            met = meet_member(member, literal, operator, scope)
            return nil if met.equal?(UNDECIDED)

            kept << met unless met.nil?
          end
          return nil if kept.empty?

          Rigor::Type::Combinator.union(*kept)
        end

        # One member's part of the meet: the member itself or its narrowing, nil when no value of it equals
        # the literal, or UNDECIDED.
        def meet_member(member, literal, operator, scope)
          class_name = member_class_name(member)
          return UNDECIDED if class_name.nil?
          return member if project_defines?(class_name, operator, scope)

          case member
          when Rigor::Type::Constant then member.value.public_send(operator, literal) ? member : nil
          when Rigor::Type::IntegerRange
            literal.is_a?(Integer) && !member.covers?(literal) ? nil : meet_class(member, class_name, literal, operator)
          else meet_class(member, class_name, literal, operator)
          end
        end

        # The core class a member's values belong to, or nil for a member that is not wholly of one. A
        # refinement (`Difference`, `Refined`) belongs to its base's class, an `Intersection` to the class all
        # its members share.
        def member_class_name(member)
          case member
          when Rigor::Type::Difference, Rigor::Type::Refined then member_class_name(member.base)
          when Rigor::Type::Intersection
            names = member.members.map { |part| member_class_name(part) }.uniq
            names.size == 1 ? names.first : nil
          when Rigor::Type::FloatRange then "Float"
          when Rigor::Type::Constant
            klass = EQUALITY_CORE_CLASSES.find { |core| member.value.instance_of?(core) }
            klass&.name
          when Rigor::Type::IntegerRange then "Integer"
          when Rigor::Type::Nominal
            name = member.class_name
            member.type_args.empty? && EQUALITY_CORE_CLASSES.any? { |core| core.name == name } ? name : nil
          end
        end

        def meet_class(member, class_name, literal, operator)
          literal_class = literal.class.name
          if class_name == literal_class
            literal.is_a?(Float) && literal.zero? ? member : Rigor::Type::Combinator.constant_of(literal)
          elsif NUMERIC_CLASS_NAMES.include?(class_name) && NUMERIC_CLASS_NAMES.include?(literal_class)
            operator == :== ? member : nil
          end
        end

        # Whether the project's source defines `operator` on the core class `class_name` or on a core ancestor
        # up to the operator's runtime owner (OPERATOR_OWNER_CHAINS): a reopening's `def`, an included or
        # prepended project module, a `define_method`. The def-node walk sees other files' `def`s and records
        # the dependency on them; the discovery table adds `define_method`. An RBS declaration is not
        # consulted: once the project reopens `String` for anything, `String#==`'s declaring owner is a
        # project class, which says nothing about who wrote `==`.
        def project_defines?(class_name, operator, scope)
          OPERATOR_OWNER_CHAINS.fetch([class_name, operator]).any? do |name|
            !scope.user_def_through_ancestors(name, operator).first.nil? ||
              scope.discovered_method_through_ancestors?(name, operator, :instance)
          end
        end

        def string_type_for_regex_arg(matcher)
          args = matcher.arguments&.arguments || []
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Prism::RegularExpressionNode) ||
                            arg.is_a?(Prism::InterpolatedRegularExpressionNode)

          Rigor::Type::Combinator.nominal_of("String")
        end

        NO_LITERAL = Object.new.freeze
        private_constant :NO_LITERAL

        # Returns the Ruby value of a literal-AST argument, or `NO_LITERAL` when the node isn't a
        # recognised literal shape. Recognised forms cover the common `eq(literal)` case: integer, float,
        # true/false/nil, string, symbol.
        def literal_value_for(node)
          case node
          when Prism::IntegerNode then node.value
          when Prism::FloatNode then node.value
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          when Prism::NilNode then nil
          when Prism::StringNode then node.unescaped
          when Prism::SymbolNode then node.unescaped.to_sym
          else NO_LITERAL
          end
        end

        def empty_args?(matcher)
          args = matcher.arguments&.arguments
          args.nil? || args.empty?
        end

        # Renders a `Prism::ConstantReadNode` / `Prism::ConstantPathNode` chain as a `"Foo::Bar"` String.
        # Returns nil when the node isn't a constant reference.
        def constant_path_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end
      end
    end
  end
end
