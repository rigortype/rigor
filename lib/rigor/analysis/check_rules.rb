# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../source/node_walker"
require_relative "../type"
require_relative "diagnostic"

module Rigor
  module Analysis
    # First-preview catalogue of `rigor check` diagnostic rules.
    #
    # The rules are intentionally narrow: they fire ONLY when the
    # engine is confident enough to make a useful claim, and they
    # MUST NOT raise on unrecognised AST shapes, RBS gaps, or
    # missing scope information. Each rule consumes the per-node
    # scope index produced by
    # `Rigor::Inference::ScopeIndexer.index` and yields zero or
    # more `Rigor::Analysis::Diagnostic` values.
    #
    # The first shipped rule, `UndefinedMethodOnTypedReceiver`,
    # flags an explicit-receiver `Prism::CallNode` whose receiver
    # statically resolves to a `Type::Nominal` or `Type::Singleton`
    # known to the analyzer's RBS environment AND whose method
    # name does not appear on that class's instance / singleton
    # method table. This is the canonical "type check" signal
    # ("Foo has no method bar"), but it explicitly does NOT fire
    # for:
    #
    # - implicit-self calls (no `node.receiver`) — too noisy
    #   without per-method RBS for every helper in the class.
    # - dynamic / unknown receivers (`Dynamic[T]`, `Top`, `Union`)
    #   — by definition we cannot enumerate the method set.
    # - shape carriers (`Tuple`, `HashShape`, `Constant`) — their
    #   dispatch goes through `ShapeDispatch` / `ConstantFolding`
    #   which the rule does not yet model.
    # - receivers whose class name is NOT registered in the
    #   loader (RBS-blind environments, unknown stdlib).
    #
    # The above list is the deliberate conservative envelope of
    # the first preview; later slices broaden it.
    # rubocop:disable Metrics/ModuleLength
    module CheckRules
      # Canonical identifiers for each rule. Per ADR-8 §
      # "Diagnostic ID family hierarchy", rule names are
      # `family.rule-name` two-segment strings; the families
      # group diagnostics by where they originate
      # (`call.*` for call-site rules, `flow.*` for flow-analysis
      # proofs, `assert.*` for runtime-assertion rules,
      # `dump.*` for debug helpers, `def.*` for method-definition
      # rules). Used by the configuration `disable:` list and the
      # in-source `# rigor:disable <rule>` suppression comment
      # system; new rules MUST register here so user configuration
      # can refer to them.
      RULE_UNDEFINED_METHOD = "call.undefined-method"
      RULE_WRONG_ARITY = "call.wrong-arity"
      RULE_ARGUMENT_TYPE = "call.argument-type-mismatch"
      RULE_NIL_RECEIVER = "call.possible-nil-receiver"
      RULE_DUMP_TYPE = "dump.type"
      RULE_ASSERT_TYPE = "assert.type-mismatch"
      RULE_ALWAYS_RAISES = "flow.always-raises"
      RULE_RETURN_TYPE = "def.return-type-mismatch"

      ALL_RULES = [
        RULE_UNDEFINED_METHOD,
        RULE_WRONG_ARITY,
        RULE_ARGUMENT_TYPE,
        RULE_NIL_RECEIVER,
        RULE_DUMP_TYPE,
        RULE_ASSERT_TYPE,
        RULE_ALWAYS_RAISES,
        RULE_RETURN_TYPE
      ].freeze

      # Backward-compat alias table (ADR-8 § "Backward
      # compatibility"). Existing user code with
      # `# rigor:disable undefined-method` /
      # `disable: [undefined-method]` keeps working — the
      # legacy unprefixed identifiers map to their canonical
      # `family.rule-name` form here. Removing the aliases is
      # a future ADR once user code has migrated; until then,
      # both spellings resolve identically.
      LEGACY_RULE_ALIASES = {
        "undefined-method" => RULE_UNDEFINED_METHOD,
        "wrong-arity" => RULE_WRONG_ARITY,
        "argument-type-mismatch" => RULE_ARGUMENT_TYPE,
        "possible-nil-receiver" => RULE_NIL_RECEIVER,
        "dump-type" => RULE_DUMP_TYPE,
        "assert-type" => RULE_ASSERT_TYPE,
        "always-raises" => RULE_ALWAYS_RAISES
      }.freeze

      # Family wildcard — a `<family>` token in a suppression
      # comment or `disable:` list disables every rule whose
      # canonical id starts with `<family>.`. Per ADR-8 § "1".
      RULE_FAMILIES = %w[call flow assert dump def].freeze

      # Resolves a user-supplied rule token (`undefined-method`,
      # `call.undefined-method`, or the family wildcard `call`)
      # to the set of canonical rule identifiers it disables.
      # Returns `nil` for `"all"` (the existing wildcard meaning
      # "every rule"), or for unknown tokens.
      def self.resolve_rule_token(token)
        return nil if token == "all"
        return [LEGACY_RULE_ALIASES.fetch(token)] if LEGACY_RULE_ALIASES.key?(token)
        return ALL_RULES.select { |r| r.start_with?("#{token}.") } if RULE_FAMILIES.include?(token)

        ALL_RULES.include?(token) ? [token] : []
      end

      module_function

      # Yields diagnostics for every unrecognised method call on
      # a typed receiver in `root`'s subtree. The caller MUST
      # have already produced `scope_index` through
      # `Rigor::Inference::ScopeIndexer.index(root, default_scope:)`.
      #
      # @param path [String] used to populate
      #   `Diagnostic#path`; the rule does not open files.
      # @param root [Prism::Node]
      # @param scope_index [Hash{Prism::Node => Rigor::Scope}]
      # @return [Array<Rigor::Analysis::Diagnostic>]
      def diagnose(path:, root:, scope_index:, comments: [], disabled_rules: [])
        diagnostics = []
        Source::NodeWalker.each(root) do |node|
          if node.is_a?(Prism::CallNode)
            diagnostics.concat(call_node_diagnostics(path, node, scope_index))
          elsif node.is_a?(Prism::DefNode)
            return_diagnostic = return_type_mismatch_diagnostic(path, node, scope_index)
            diagnostics << return_diagnostic if return_diagnostic
          end
        end
        filter_suppressed(diagnostics, comments: comments, disabled_rules: disabled_rules)
      end

      def call_node_diagnostics(path, node, scope_index)
        [
          undefined_method_diagnostic(path, node, scope_index),
          wrong_arity_diagnostic(path, node, scope_index),
          argument_type_diagnostic(path, node, scope_index),
          nil_receiver_diagnostic(path, node, scope_index),
          dump_type_diagnostic(path, node, scope_index),
          assert_type_diagnostic(path, node, scope_index),
          always_raises_diagnostic(path, node, scope_index)
        ].compact
      end

      # v0.0.2 #6 — diagnostic suppression. Two kinds of
      # suppression compose:
      #
      # - **Project-level**: `disabled_rules` is the
      #   project's `.rigor.yml` `disable:` list. Any
      #   diagnostic whose `rule` is in the list is dropped.
      # - **In-source**: `# rigor:disable <rule1>, <rule2>`
      #   on the same line as the offending expression
      #   suppresses the matching diagnostic for that line
      #   only. `# rigor:disable all` on a line suppresses
      #   every rule on that line.
      #
      # Diagnostics with `rule == nil` (parse errors, path
      # errors, internal analyzer errors) are NEVER
      # suppressed — they represent failures the user cannot
      # silence away.
      def filter_suppressed(diagnostics, comments:, disabled_rules:)
        suppressions = parse_suppression_comments(comments)
        disabled = expand_rule_tokens(disabled_rules)

        diagnostics.reject do |diagnostic|
          rule = diagnostic.rule
          next false if rule.nil?
          next true if disabled.include?(rule)

          line_rules = suppressions[diagnostic.line]
          line_rules && (line_rules.include?("all") || line_rules.include?(rule))
        end
      end

      SUPPRESSION_PATTERN = /#\s*rigor:disable\s+(?<rules>[\w.,\s-]+)/
      private_constant :SUPPRESSION_PATTERN

      def parse_suppression_comments(comments)
        result = Hash.new { |h, k| h[k] = Set.new }
        comments.each do |comment|
          source = comment.location.slice
          match = SUPPRESSION_PATTERN.match(source)
          next if match.nil?

          rules = match[:rules].to_s.split(/[\s,]+/).reject(&:empty?)
          rules.each { |token| result[comment.location.start_line].merge(expand_token(token)) }
        end
        result
      end

      # Expands a list of user-supplied rule tokens into the
      # canonical-id set per ADR-8 § "Backward compatibility".
      # `disabled_rules` accepts unprefixed legacy names
      # (`undefined-method`), canonical names
      # (`call.undefined-method`), and family wildcards (`call`).
      def expand_rule_tokens(tokens)
        Array(tokens).each_with_object(Set.new) do |token, set|
          set.merge(expand_token(token.to_s))
        end
      end

      def expand_token(token)
        return ["all"] if token == "all"

        resolved = resolve_rule_token(token)
        resolved.nil? || resolved.empty? ? [token] : resolved
      end

      # rubocop:disable Metrics/ClassLength
      class << self
        private

        def undefined_method_diagnostic(path, call_node, scope_index) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return nil if call_node.receiver.nil?

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # Slice 7 phase 12 — suppress when the user has
          # declared the method in source (instance `def`,
          # `def self.foo`, or recognised `define_method`).
          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          return nil if scope.discovered_method?(class_name, call_node.name, kind)

          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          # When the loader cannot build a class definition for a
          # name it nominally knows (constant-decl aliases such
          # as `YAML` → `Psych`, or RBS-build failures for
          # malformed signatures), we cannot enumerate methods
          # so we MUST NOT emit a false positive. Skip the rule
          # in that case.
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def

          build_undefined_method_diagnostic(path, call_node, receiver_type)
        end

        # Returns a qualified class name for the in-scope check.
        # Nominal / Singleton carry a single-class identity
        # directly. Constant projects to its value's class.
        # Tuple projects to "Array" and HashShape to "Hash" so
        # arity / dispatch checks against the underlying class
        # still apply. Dynamic / Top / Union / Bot do not name a
        # single class and return nil to skip the rule.
        def concrete_class_name(type)
          case type
          when Type::Nominal, Type::Singleton then type.class_name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::Constant then constant_class_name(type.value)
          end
        end

        CONSTANT_CLASSES = {
          Integer => "Integer", Float => "Float", String => "String",
          Symbol => "Symbol", Range => "Range",
          TrueClass => "TrueClass", FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_CLASSES

        def constant_class_name(value)
          CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
          nil
        end

        def definition_available?(receiver_type, class_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            !Rigor::Reflection.singleton_definition(class_name, scope: scope).nil?
          else
            !Rigor::Reflection.instance_definition(class_name, scope: scope).nil?
          end
        end

        def lookup_method(receiver_type, class_name, method_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: scope)
          else
            Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
          end
        rescue StandardError
          # The Reflection facade catches loader exceptions and
          # returns nil. The wrapper here treats failures as
          # "method exists" so we do NOT emit a false positive
          # when our knowledge of the receiver class is
          # structurally incomplete (Reflection's own rescue
          # already returns nil; this catch is a defensive
          # double-net for any future call shape that might
          # raise).
          true
        end

        # Slice 7 phase 11 — wrong-arity diagnostic. Fires when
        # an explicit-receiver `Prism::CallNode` resolves to a
        # method whose declared overloads do not admit the
        # supplied positional argument count. The rule applies
        # ONLY to the simplest overload shape (single overload,
        # no `rest_positionals`, no keyword parameters, no
        # block-required positionals); calls with `*splat`
        # arguments, keyword arguments, or block-pass arguments
        # are silently skipped to avoid false positives. The
        # check piggybacks on the same scope-index lookup used
        # by `undefined_method_diagnostic`; it returns nil
        # when the call's receiver / RBS coverage / call shape
        # disqualifies the rule.
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def wrong_arity_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          return nil unless plain_positional_call?(call_node)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          return nil if scope.discovered_method?(class_name, call_node.name, kind)

          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def.nil? || method_def == true

          arity_envelope = compute_arity_envelope(method_def)
          return nil if arity_envelope.nil?

          actual = (call_node.arguments&.arguments || []).size
          min, max = arity_envelope
          return nil if actual.between?(min, max)

          build_arity_diagnostic(path, call_node, class_name, min, max, actual)
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def plain_positional_call?(call_node)
          arguments = call_node.arguments
          return true if arguments.nil?

          arguments.arguments.all? { |arg| simple_positional?(arg) }
        end

        def simple_positional?(arg)
          return false if arg.is_a?(Prism::SplatNode)
          return false if arg.is_a?(Prism::KeywordHashNode)
          return false if arg.is_a?(Prism::BlockArgumentNode)
          return false if arg.is_a?(Prism::ForwardingArgumentsNode)

          true
        end

        # Returns `[min, max]` positional-argument arity for the
        # method (across all overloads), or nil when the rule
        # does not apply. We disqualify only when the method
        # uses required keyword arguments (which the caller MUST
        # pass at the call site, and our plain-positional check
        # would not have caught) or trailing positionals (rare,
        # complex). `optional_keywords` and `rest_keywords` do
        # NOT affect positional arity. `rest_positionals` raises
        # `max` to `Float::INFINITY`.
        def compute_arity_envelope(method_def)
          mins = []
          maxes = []
          method_def.method_types.each do |mt|
            function = mt.type
            return nil unless arity_eligible?(function)

            min_arity = function.required_positionals.size
            max_arity =
              if function.rest_positionals
                Float::INFINITY
              else
                min_arity + function.optional_positionals.size
              end
            mins << min_arity
            maxes << max_arity
          end
          return nil if mins.empty?

          [mins.min, maxes.max]
        end

        def arity_eligible?(function)
          # `RBS::Types::UntypedFunction` (used for `(?) ->`
          # untyped sigs) does not expose the per-arity
          # accessors. Treating it as ineligible is the
          # correct conservative move: an untyped function
          # has no static arity to enforce.
          return false unless function.respond_to?(:required_keywords)

          function.required_keywords.empty? && function.trailing_positionals.empty?
        end

        # Slice 7 phase 14 — nil-receiver diagnostic. Fires when
        # the receiver type is a `Type::Union` containing a
        # nil-bearing member (`Constant[nil]` or
        # `Nominal[NilClass]`) AND the called method does not
        # exist on `NilClass`. This is the canonical "you forgot
        # to nil-check before calling X" signal: the engine has
        # proved that on at least one execution path the receiver
        # is nil, and the call would raise NoMethodError.
        #
        # The rule deliberately ignores receivers that are
        # exactly `Constant[nil]` / `Nominal[NilClass]` (those
        # are already covered by `undefined_method_diagnostic`)
        # and union receivers where every member already
        # disqualifies the call (avoid duplicating the
        # undefined-method diagnostic).
        def nil_receiver_diagnostic(path, call_node, scope_index) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return nil if call_node.receiver.nil?
          # Safe-navigation calls (`recv&.method`) already
          # short-circuit on nil at runtime, so a nil-bearing
          # receiver is not a bug for them.
          return nil if call_node.safe_navigation?
          # Restrict to direct local-variable reads. Local
          # narrowing (Slice 6 phase 1) is the only narrowing
          # surface that can prove a guard like
          # `return if x.nil?` removed nil from the union, so
          # firing on chained / method-call receivers would
          # produce false positives we cannot suppress.
          return nil unless call_node.receiver.is_a?(Prism::LocalVariableReadNode)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          return nil unless receiver_type.is_a?(Type::Union)

          # The rule only fires when the analyzer has access to
          # an RBS loader; without it, the per-member method-
          # presence checks below cannot rule out a sound call.
          return nil unless Rigor::Reflection.rbs_class_known?("NilClass", scope: scope)

          return nil unless union_contains_nil?(receiver_type)
          return nil unless union_method_present_on_non_nil?(receiver_type, call_node.name, scope)
          return nil if nil_class_has_method?(call_node.name, scope)

          build_nil_receiver_diagnostic(path, call_node)
        end

        def union_contains_nil?(union)
          union.members.any? { |member| nil_member?(member) }
        end

        def nil_member?(member)
          (member.is_a?(Type::Constant) && member.value.nil?) ||
            (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
        end

        # The non-nil members must collectively support the
        # method (i.e. for every non-nil member, the method
        # exists on its class via RBS or in-source discovery).
        # Without this guard, the rule would also fire on calls
        # that are unsound on the non-nil branch — that is the
        # `undefined_method_diagnostic` rule's job, and we want
        # exactly one diagnostic per offending call site.
        def union_method_present_on_non_nil?(union, method_name, scope)
          non_nil_members = union.members.reject { |m| nil_member?(m) }
          return false if non_nil_members.empty?

          non_nil_members.all? { |m| method_present_anywhere?(m, method_name, scope) }
        end

        def method_present_anywhere?(member, method_name, scope)
          class_name = concrete_class_name(member)
          return true if class_name.nil? # Dynamic / Top / Bot — be permissive.
          return true if scope.discovered_method?(class_name, method_name, :instance)
          return true unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return true unless definition_available?(member, class_name, scope)

          !lookup_method(member, class_name, method_name, scope).nil?
        end

        def nil_class_has_method?(method_name, scope)
          definition = Rigor::Reflection.instance_definition("NilClass", scope: scope)
          return false if definition.nil?

          !definition.methods[method_name.to_sym].nil?
        end

        # Slice 7 phase 19 — PHPStan-style `dump_type(value)`.
        # When the engine recognises a call to `dump_type` (with
        # any of the supported receiver shapes — implicit self
        # after `include Rigor::Testing`, `Rigor::Testing.dump_type`,
        # or `Rigor.dump_type`), it emits an `:info` diagnostic
        # showing the inferred type of the argument expression.
        # The diagnostic does NOT count toward `Result#error_count`
        # so a fixture peppered with `dump_type` calls still
        # passes `rigor check`.
        def dump_type_diagnostic(path, call_node, scope_index) # rubocop:disable Metrics/CyclomaticComplexity
          return nil unless rigor_testing_call?(call_node, :dump_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.empty?

          arg = call_node.arguments.arguments.first
          scope = scope_index[arg] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          type = scope.type_of(arg)
          location = call_node.message_loc || call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: "dump_type: #{type.describe(:short)}",
            severity: :info,
            rule: RULE_DUMP_TYPE
          )
        end

        # Slice 7 phase 19 — PHPStan-style `assert_type("...", value)`.
        # The first argument MUST be a string literal containing
        # the expected `Type#describe(:short)` rendering. When
        # the inferred type's short description does not equal
        # the expected literal, an `:error`-severity diagnostic
        # is emitted; matching calls produce no output. This
        # lets a fixture document its expected types inline:
        # subsequent `rigor check` runs flag any drift.
        def assert_type_diagnostic(path, call_node, scope_index) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return nil unless rigor_testing_call?(call_node, :assert_type)
          return nil if call_node.arguments.nil? || call_node.arguments.arguments.size < 2

          expected_node = call_node.arguments.arguments.first
          return nil unless expected_node.is_a?(Prism::StringNode)

          value_node = call_node.arguments.arguments[1]
          scope = scope_index[value_node] || scope_index[call_node]
          return nil if scope.nil?
          return nil if inside_rigor_testing?(scope)

          actual = scope.type_of(value_node).describe(:short)
          expected = expected_node.unescaped.to_s
          return nil if actual == expected

          build_assert_type_diagnostic(path, call_node, expected, actual)
        end

        # Recognises any of:
        #   `dump_type(x)`        (implicit self after `include Rigor::Testing`)
        #   `Testing.dump_type(x)`
        #   `Rigor.dump_type(x)`
        #   `Rigor::Testing.dump_type(x)`
        # The receiver check is purely structural — we do not
        # consult RBS — because the helpers are no-op stubs the
        # user MAY shadow with their own definition; a name
        # clash is the deliberate trade-off for ergonomic
        # invocation.
        RIGOR_TESTING_RECEIVERS = ["Rigor", "Rigor::Testing", "Testing"].freeze
        private_constant :RIGOR_TESTING_RECEIVERS

        # The dump/assert helpers' own implementation methods
        # call back into `Testing.dump_type` / `assert_type` to
        # share the no-op runtime stub. We do NOT want those
        # internal calls to surface diagnostics — they are
        # reflexive plumbing, not user assertions. This filter
        # skips diagnostics when the call site's `self_type` is
        # the `Rigor` or `Rigor::Testing` module itself.
        SELF_REFERENTIAL_SCOPES = ["Rigor", "Rigor::Testing"].freeze
        private_constant :SELF_REFERENTIAL_SCOPES

        def inside_rigor_testing?(scope)
          self_type = scope.self_type
          return false if self_type.nil?
          return false unless self_type.respond_to?(:class_name)

          SELF_REFERENTIAL_SCOPES.include?(self_type.class_name)
        end

        def rigor_testing_call?(call_node, method_name)
          return false unless call_node.name == method_name

          receiver = call_node.receiver
          return true if receiver.nil?

          name = constant_name_of(receiver)
          return false if name.nil?

          RIGOR_TESTING_RECEIVERS.include?(name)
        end

        def constant_name_of(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then render_constant_path(node)
          end
        end

        def render_constant_path(node)
          parent = node.parent
          base = constant_name_of(parent)
          return nil if parent && base.nil?

          parent ? "#{base}::#{node.name}" : node.name.to_s
        end

        def build_assert_type_diagnostic(path, call_node, expected, actual)
          location = call_node.message_loc || call_node.location
          Diagnostic.new(
            rule: RULE_ASSERT_TYPE,
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: "assert_type mismatch: expected #{expected.inspect}, got #{actual.inspect}",
            severity: :error
          )
        end

        def build_nil_receiver_diagnostic(path, call_node)
          location = call_node.message_loc || call_node.location
          Diagnostic.new(
            rule: RULE_NIL_RECEIVER,
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: "possible nil receiver: `#{call_node.name}' is undefined on NilClass",
            severity: :error
          )
        end

        # Diagnoses calls that the analyzer can prove will always
        # raise. Today the only triggering shape is integer
        # division/modulo by a literal zero divisor:
        #
        #   5 / 0          # => ZeroDivisionError
        #   x.modulo(0)    # => ZeroDivisionError when x: Integer
        #   xs.size % 0    # same — non_negative_int / Constant[0]
        #
        # Float divmod by zero returns Infinity/NaN at runtime, so
        # the rule restricts to Integer-rooted receivers (`Constant`,
        # `IntegerRange`, `Nominal[Integer]`). The argument MUST be a
        # `Constant<Integer>` whose value is exactly zero — a
        # `Union[Constant[0], Constant[2]]` divisor "may" raise,
        # which we surface separately (future slice).
        INTEGER_RAISING_OPERATORS = %i[/ % div modulo divmod].freeze
        private_constant :INTEGER_RAISING_OPERATORS

        def always_raises_diagnostic(path, call_node, scope_index)
          return nil unless integer_zero_division?(call_node, scope_index)

          build_always_raises_diagnostic(path, call_node)
        end

        def integer_zero_division?(call_node, scope_index)
          return false unless raising_call_shape?(call_node)

          scope = scope_index[call_node]
          return false if scope.nil?
          return false unless integer_rooted_for_diagnostic?(scope.type_of(call_node.receiver))

          arg = single_argument(call_node)
          arg && integer_zero_constant?(scope.type_of(arg))
        end

        def raising_call_shape?(call_node)
          !call_node.receiver.nil? && INTEGER_RAISING_OPERATORS.include?(call_node.name)
        end

        def single_argument(call_node)
          args = call_node.arguments&.arguments || []
          args.size == 1 ? args.first : nil
        end

        def integer_rooted_for_diagnostic?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?
          else false
          end
        end

        def integer_zero_constant?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.zero?
        end

        def build_always_raises_diagnostic(path, call_node)
          location = call_node.message_loc || call_node.location
          Diagnostic.new(
            rule: RULE_ALWAYS_RAISES,
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: "always raises ZeroDivisionError: `#{call_node.name}' by zero on Integer receiver",
            severity: :error
          )
        end

        # v0.0.2 #4 — argument-type-mismatch diagnostic.
        # Walks a call's positional arguments and checks each
        # against the matching parameter's RBS type via
        # `Rigor::Inference::Acceptance`. Emits an `:error`
        # for the first argument whose type the parameter
        # does NOT accept under the gradual mode.
        #
        # Conservative envelope (matches the wrong-arity rule
        # plus a few additional skips):
        # - Receiver must be Nominal / Singleton / Constant
        #   (the same `concrete_class_name` test).
        # - Method must be in RBS.
        # - Method must have exactly ONE method type
        #   (overload). Multi-overload checking is left for
        #   a follow-up because picking the "intended"
        #   overload requires the dispatcher's full
        #   acceptance plumbing.
        # - The selected overload must have NO
        #   rest_positionals, NO required keywords, NO
        #   trailing positionals.
        # - The call must use plain positional arguments
        #   (no splat / kw / block-pass / forwarded).
        # - Per-argument: skip when EITHER side is `Dynamic`
        #   (the call cannot be statically refuted).
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
        def argument_type_diagnostic(path, call_node, scope_index)
          return nil if call_node.receiver.nil?
          return nil unless plain_positional_call?(call_node)

          scope = scope_index[call_node]
          return nil if scope.nil?

          receiver_type = scope.type_of(call_node.receiver)
          class_name = concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # NOTE: unlike the undefined-method / wrong-arity
          # rules, we deliberately do NOT skip when
          # `discovered_method?` matches. When the user
          # supplies BOTH a `def` and an RBS sig, the sig is
          # the authoritative parameter contract and we
          # should validate calls against it.
          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless definition_available?(receiver_type, class_name, scope)

          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def.nil? || method_def == true
          return nil unless method_def.method_types.size == 1

          param_overrides = Rigor::RbsExtended.param_type_override_map(method_def)
          mismatch = first_argument_mismatch(method_def.method_types.first, call_node, scope, param_overrides)
          return nil if mismatch.nil?

          build_argument_type_diagnostic(path, call_node, class_name, mismatch)
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
        def first_argument_mismatch(method_type, call_node, scope, param_overrides)
          function = method_type.type
          return nil unless argument_check_eligible?(function)

          params = function.required_positionals + function.optional_positionals
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            param = params[index]
            next if param.nil? # arity mismatch is the wrong-arity rule's concern.

            # `rigor:v1:param: <name> <refinement>` annotations
            # tighten the RBS-declared parameter type. The
            # override is the authoritative contract when
            # present; otherwise we translate the RBS type as
            # before.
            param_type = param_overrides[param.name] || translate_param_type(param.type, scope.environment)
            next if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)

            arg_type = scope.type_of(arg)
            next if arg_type.is_a?(Type::Dynamic) || arg_type.is_a?(Type::Top)

            result = Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual)
            return { node: arg, name: param.name, expected: param_type, actual: arg_type } if result.no?
          end
          nil
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize

        def argument_check_eligible?(function)
          # See `arity_eligible?`: `UntypedFunction` lacks
          # the per-arity accessors. Treat it as ineligible
          # for argument-type-mismatch diagnostics.
          return false unless function.respond_to?(:required_keywords)

          function.rest_positionals.nil? &&
            function.required_keywords.empty? &&
            function.optional_keywords.empty? &&
            function.rest_keywords.nil? &&
            function.trailing_positionals.empty?
        end

        def translate_param_type(rbs_type, _environment)
          Inference::RbsTypeTranslator.translate(rbs_type)
        rescue StandardError
          Type::Combinator.untyped
        end

        def build_argument_type_diagnostic(path, call_node, class_name, mismatch)
          location = mismatch[:node].location
          method_label = "`#{call_node.name}' on #{class_name}"
          parameter_label = mismatch[:name] ? "parameter `#{mismatch[:name]}' of #{method_label}" : method_label
          message = "argument type mismatch at #{parameter_label}: " \
                    "expected #{mismatch[:expected].describe(:short)}, " \
                    "got #{mismatch[:actual].describe(:short)}"
          Diagnostic.new(
            rule: RULE_ARGUMENT_TYPE,
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: message,
            severity: :error
          )
        end

        # rubocop:disable Metrics/ParameterLists
        def build_arity_diagnostic(path, call_node, class_name, min, max, actual)
          location = call_node.message_loc || call_node.location
          range = min == max ? min.to_s : "#{min}..#{max}"
          method_label = "`#{call_node.name}' on #{class_name}"
          message = "wrong number of arguments to #{method_label} (given #{actual}, expected #{range})"
          Diagnostic.new(
            rule: RULE_WRONG_ARITY,
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: message,
            severity: :error
          )
        end
        # rubocop:enable Metrics/ParameterLists

        def build_undefined_method_diagnostic(path, call_node, receiver_type)
          location = call_node.message_loc || call_node.location
          rendered_receiver = receiver_type.describe
          Diagnostic.new(
            rule: RULE_UNDEFINED_METHOD,
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: "undefined method `#{call_node.name}' for #{rendered_receiver}",
            severity: :error
          )
        end

        # ADR-8 § "`def.return-type-mismatch` rule" — flags a
        # `def m(...) ... end` whose body's last expression's
        # type cannot satisfy the RBS-declared return type.
        # Conservative envelope (v0.1.x first cut):
        #
        # - Skips methods without an RBS declaration. The rule
        #   has no contract to compare against for source-only
        #   methods.
        # - Skips methods whose enclosing class isn't a
        #   `Type::Singleton` self_type that we can name (top-
        #   level / module-level methods land outside the rule).
        # - Skips methods whose body's last expression is
        #   absent or types as `Dynamic[top]` (the analyzer's
        #   fail-soft fallback) — emitting on `Dynamic[top]`
        #   would be noise.
        # - Compares the inferred body type against the
        #   declared return via `accepts?`:
        #     :yes   → silent
        #     :no    → emit at :error (severity_profile may
        #              re-stamp; default `balanced` keeps the
        #              authored severity).
        #     :maybe → emit at :warning. Promoted to :error
        #              under `severity_profile: strict` per
        #              ADR-8 § "Severity profile".
        def return_type_mismatch_diagnostic(path, def_node, scope_index) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          return nil if def_node.body.nil?

          last_expr = body_last_expression(def_node.body)
          return nil if last_expr.nil?

          inner_scope = scope_index[last_expr] || scope_index[def_node.body] || scope_index[def_node]
          return nil if inner_scope.nil?

          declared = declared_return_type(def_node, scope_index)
          return nil if declared.nil?

          inferred = inner_scope.type_of(last_expr)
          return nil if dynamic_top?(inferred)

          severity = compare_return(declared, inferred)
          return nil if severity.nil?

          build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
        end

        # The body of a `def` is the last `Prism::StatementsNode`
        # child (or a single expression for one-liner defs).
        # Take the last statement; that's the implicit return.
        def body_last_expression(body)
          case body
          when Prism::StatementsNode then body.body.last
          when Prism::BeginNode then body_last_expression(body.statements)
          else body
          end
        end

        # Pulls the declared RBS return type for the def. The
        # enclosing class name comes from the def's scope's
        # `self_type`; the method name is on the def itself.
        # `def self.foo` is a singleton method — dispatched
        # through `Reflection.singleton_method_definition`;
        # plain `def foo` uses `instance_method_definition`.
        # Method overloads contribute their union of declared
        # return types (any one of them satisfying the body
        # silences the rule).
        def declared_return_type(def_node, scope_index)
          scope = scope_index[def_node]
          return nil if scope.nil?

          self_type = scope.self_type
          return nil unless self_type.respond_to?(:class_name)

          method_def =
            if def_node.receiver.nil?
              Reflection.instance_method_definition(self_type.class_name, def_node.name, scope: scope)
            else
              Reflection.singleton_method_definition(self_type.class_name, def_node.name, scope: scope)
            end
          return nil if method_def.nil?

          declared_return_union(method_def, scope.environment)
        end

        def declared_return_union(method_def, _environment)
          translated = method_def.method_types.filter_map do |mt|
            Inference::RbsTypeTranslator.translate(
              mt.type.return_type,
              self_type: nil, instance_type: nil, type_vars: {}
            )
          rescue StandardError
            nil
          end
          return nil if translated.empty?

          translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
        end

        def dynamic_top?(type)
          type.is_a?(Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
        end

        # Returns the severity to emit at, or nil to stay
        # silent. The first-cut implementation only fires on
        # proven (`:no`) mismatches; `:maybe` is treated as
        # silent until the analyzer's narrowing becomes precise
        # enough to avoid noise on common patterns (`{}` →
        # declared `Hash[K, V]`, `Set.new` → declared
        # `Set[Symbol]`, …). ADR-8's promise to emit on
        # `:maybe` under `severity_profile: strict` is
        # deferred to a follow-up that lands together with the
        # narrowing precision improvements.
        def compare_return(declared, inferred)
          result = declared.accepts(inferred)
          return :error if result.no?

          nil
        end

        def build_return_type_mismatch_diagnostic(path, def_node, declared, inferred, severity)
          location = def_node.name_loc || def_node.location
          Diagnostic.new(
            rule: RULE_RETURN_TYPE,
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: "return-type mismatch on `#{def_node.name}': " \
                     "declared #{declared.describe(:short)}, inferred #{inferred.describe(:short)}",
            severity: severity
          )
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
