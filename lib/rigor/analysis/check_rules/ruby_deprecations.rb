# frozen_string_literal: true

require "prism"

require_relative "rule_ids"
require_relative "../diagnostic"
require_relative "../../inference/version_guard"
require_relative "../../source/constant_path"

module Rigor
  module Analysis
    module CheckRules
      # Issue #1692 (the ADR-47 WD5 amendment) — `call.deprecated-ruby2-keywords`: a call to a method of the
      # `ruby2_keywords` family, which Ruby 4.1 deprecates (Feature #22205). `Module#ruby2_keywords`, top-level
      # `ruby2_keywords` and `Proc#ruby2_keywords` are removed in Ruby 4.4, `Hash.ruby2_keywords_hash?` and
      # `Hash.ruby2_keywords_hash` in Ruby 4.5.
      #
      # The rule runs only when `.rigor.yml` states the runtime: `target_ruby` set explicitly to 4.1 or later
      # ({Configuration#stated_runtime_ruby}). On Ruby 4.0 the same calls are correct and silent, so the default
      # `target_ruby` fires nothing. The file walk is paid only by a project that states such a target.
      #
      # A call counts only where it can reach the core method and nothing else:
      #
      # - `ruby2_keywords` with no receiver (or `self`), in a class or module body, a `class << self` body or a
      #   singleton method, where `self` is a Module. At the top level outside any block, it is the `main`
      #   method. Inside a block whose `self` the engine does not know (a top-level block, or any
      #   `instance_eval` / `instance_exec` block), and in an instance method, it is not judged.
      # - `ruby2_keywords` on a receiver typed `Proc`.
      # - `ruby2_keywords_hash?` / `ruby2_keywords_hash` on `Hash` or a class RBS knows as its subclass, or with
      #   no receiver where `self` is one.
      # - The same names through `send` / `__send__` with a literal Symbol, which also reach the private
      #   `Module#ruby2_keywords` on an explicit Module receiver.
      #
      # A project or `pre_eval:` file that defines a method by the same name anywhere silences that name, since
      # the call may then reach the project's method. A call in an arm of a version guard that cannot run on the
      # stated Ruby, or whose guard cannot be decided, is not reported, nor are the statements after a guard
      # that jumps away (`return if RUBY_VERSION < "2.7"`).
      module RubyDeprecations
        module_function

        # The first Ruby that deprecates the family.
        DEPRECATED_SINCE = ::Gem::Version.new("4.1")

        MODULE_FORM = ["Module#ruby2_keywords", "4.4"].freeze
        TOPLEVEL_FORM = ["top-level ruby2_keywords", "4.4"].freeze
        PROC_FORM = ["Proc#ruby2_keywords", "4.4"].freeze
        HASH_FORMS = {
          ruby2_keywords_hash?: ["Hash.ruby2_keywords_hash?", "4.5"].freeze,
          ruby2_keywords_hash: ["Hash.ruby2_keywords_hash", "4.5"].freeze
        }.freeze
        NAMES = (%i[ruby2_keywords] + HASH_FORMS.keys).freeze
        SEND_NAMES = %i[send __send__].freeze
        INSTANCE_EVAL_NAMES = %i[instance_eval instance_exec].freeze
        SCOPE_BOUNDARIES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        # Where Ruby looks a Module receiver's private `ruby2_keywords` up, besides the receiver itself.
        MODULE_OWNERS = %w[Module Class Object Kernel BasicObject].freeze
        private_constant :MODULE_FORM, :TOPLEVEL_FORM, :PROC_FORM, :HASH_FORMS, :NAMES, :SEND_NAMES,
                         :INSTANCE_EVAL_NAMES, :SCOPE_BOUNDARIES, :MODULE_OWNERS

        # The walk's lexical context: whether a block hides `self`, and whether a version guard makes the node
        # unreportable.
        Context = Data.define(:in_block, :in_instance_eval, :guarded)
        ROOT_CONTEXT = Context.new(in_block: false, in_instance_eval: false, guarded: false)
        private_constant :Context, :ROOT_CONTEXT

        # @param stated_ruby — {Configuration#stated_runtime_ruby}, or nil
        # @return whether the rule runs at all for this target
        def active?(stated_ruby)
          return false if stated_ruby.nil? || !::Gem::Version.correct?(stated_ruby)

          ::Gem::Version.new(stated_ruby) >= DEPRECATED_SINCE
        end

        def diagnostics(path, root, scope_index, stated_ruby)
          return [] unless active?(stated_ruby)

          guard_ruby = guard_version(stated_ruby)
          results = []
          shadowed = {}
          walk(root, ROOT_CONTEXT, guard_ruby) do |call, context|
            form = deprecated_form(call, context, scope_index, shadowed)
            results << build(path, call, form, stated_ruby) if form
          end
          results
        end

        # `RUBY_VERSION` reads `"4.1.0"` on Ruby 4.1, so a stated `"4.1"` is padded before a guard compares it
        # as a String.
        def guard_version(stated_ruby)
          segments = stated_ruby.split(".")
          (segments + (["0"] * (3 - segments.size))).join(".")
        end

        def walk(node, context, guard_ruby, &)
          # Nothing under a guarded node is reported, so the walk does not descend into it.
          return if !node.is_a?(Prism::Node) || context.guarded

          yield node, context if node.is_a?(Prism::CallNode) && candidate?(node)

          jumped = false
          node.rigor_each_child do |child|
            child_context = child_context(node, child, context, guard_ruby)
            child_context = child_context.with(guarded: true) if jumped
            walk(child, child_context, guard_ruby, &)
            jumped ||= node.is_a?(Prism::StatementsNode) && jumping_version_guard?(child)
          end
        end

        def candidate?(call)
          return true if NAMES.include?(call.name)

          SEND_NAMES.include?(call.name) && NAMES.include?(send_target(call))
        end

        # The Symbol a `send` names as its first argument, or nil.
        def send_target(call)
          first = call.arguments&.arguments&.first
          first.is_a?(Prism::SymbolNode) ? first.unescaped.to_sym : nil
        end

        def child_context(node, child, context, guard_ruby)
          if SCOPE_BOUNDARIES.any? { |klass| node.is_a?(klass) }
            context = context.with(in_block: false, in_instance_eval: false)
          end
          if node.is_a?(Prism::CallNode) && child.equal?(node.block) && child.is_a?(Prism::BlockNode)
            context = context.with(in_block: true,
                                   in_instance_eval: context.in_instance_eval || INSTANCE_EVAL_NAMES.include?(node.name))
          end
          return context if context.guarded

          version_guard_live?(node, child, guard_ruby) ? context : context.with(guarded: true)
        end

        # Whether `child` stays reportable under `node`'s condition. An `if` / `unless` arm is, when its guard is
        # decided on the stated Ruby and selects it. Any other branch of a conditional whose condition reads
        # `RUBY_VERSION` is not, because the stated version is the lowest one the project runs on and an
        # undecided guard may deselect the call on it.
        def version_guard_live?(node, child, guard_ruby)
          case node
          when Prism::IfNode, Prism::UnlessNode
            return true if child.equal?(node.predicate) || !reads_ruby_version?(node.predicate)

            arm_live?(node, child, guard_ruby)
          when Prism::CaseNode, Prism::CaseMatchNode, Prism::WhileNode, Prism::UntilNode
            condition = node.predicate
            condition.nil? || child.equal?(condition) || !reads_ruby_version?(condition)
          when Prism::AndNode, Prism::OrNode
            child.equal?(node.left) || !reads_ruby_version?(node.left)
          else
            true
          end
        end

        def arm_live?(node, child, guard_ruby)
          verdict = Inference::VersionGuard.verdict(node.predicate, stated_ruby: guard_ruby)
          return false if verdict.nil?

          then_live = verdict == (node.is_a?(Prism::IfNode) ? :truthy : :falsey)
          child.equal?(node.statements) ? then_live : !then_live
        end

        # `return if RUBY_VERSION < "2.7"` (or `raise` / `next` / `break` under such a guard): the statements
        # after it run only on the Rubies the guard lets through.
        def jumping_version_guard?(node)
          return false unless node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
          return false unless reads_ruby_version?(node.predicate)

          contains_jump?(node.statements) || contains_jump?(node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause)
        end

        JUMP_CALLS = %i[raise fail exit exit! abort].freeze
        private_constant :JUMP_CALLS

        def contains_jump?(node)
          return false unless node.is_a?(Prism::Node)

          case node
          when Prism::ReturnNode, Prism::NextNode, Prism::BreakNode then return true
          when Prism::CallNode then return true if node.receiver.nil? && JUMP_CALLS.include?(node.name)
          end
          found = false
          node.rigor_each_child { |child| found ||= contains_jump?(child) }
          found
        end

        def reads_ruby_version?(node)
          return false unless node.is_a?(Prism::Node)
          return true if (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) &&
                         Source::ConstantPath.qualified_name_or_nil(node) == "RUBY_VERSION"

          found = false
          node.rigor_each_child { |child| found ||= reads_ruby_version?(child) }
          found
        end

        # @return `[display, removal]` for a call that reaches a deprecated method, or nil
        def deprecated_form(call, context, scope_index, shadowed)
          scope = scope_index[call]
          return nil if scope.nil?

          via_send = SEND_NAMES.include?(call.name)
          name = via_send ? send_target(call) : call.name
          shadowed[name] = project_defines?(scope, name) unless shadowed.key?(name)
          return nil if shadowed[name]

          receiver = call.receiver
          if receiver.nil? || receiver.is_a?(Prism::SelfNode)
            self_form(name, scope, context)
          else
            receiver_form(name, scope.type_of(receiver), scope, via_send)
          end
        end

        def self_form(name, scope, context)
          self_type = scope.self_type
          if self_type.nil?
            return nil if context.in_block || name != :ruby2_keywords

            return TOPLEVEL_FORM
          end
          return nil if context.in_instance_eval || !self_type.is_a?(Type::Singleton)

          name == :ruby2_keywords ? MODULE_FORM : hash_form(name, self_type, scope)
        end

        def receiver_form(name, type, scope, via_send)
          if name == :ruby2_keywords
            return PROC_FORM if type.is_a?(Type::Nominal) && class_at_or_below?(type.class_name, "Proc", scope)

            # `Module#ruby2_keywords` is private: only `send` reaches it on an explicit receiver.
            return via_send && type.is_a?(Type::Singleton) ? MODULE_FORM : nil
          end
          type.is_a?(Type::Singleton) ? hash_form(name, type, scope) : nil
        end

        def hash_form(name, singleton, scope)
          return nil unless HASH_FORMS.key?(name)

          class_at_or_below?(singleton.class_name, "Hash", scope) ? HASH_FORMS.fetch(name) : nil
        end

        def class_at_or_below?(class_name, ancestor, scope)
          return true if class_name == ancestor
          return false if scope.environment.nil?

          %i[equal subclass].include?(Rigor::Reflection.class_ordering(class_name, ancestor, scope: scope))
        end

        # Whether a project or `pre_eval:` file defines a method called `name` anywhere — on any class, on either
        # side, or at the top level. Asked once per name per file.
        def project_defines?(scope, name)
          return true if scope.discovered_methods.any? { |_owner, table| table.key?(name) }
          return true if scope.discovered_def_nodes.any? { |_owner, table| table.key?(name) }

          registry = scope.environment&.project_patched_methods
          return false if registry.nil? || registry.empty?

          registry.by_key.each_key.any? { |(_owner, method_name, _kind)| method_name == name }
        end

        def build(path, call, form, stated_ruby)
          display, removal = form
          tail = if ::Gem::Version.new(stated_ruby) >= ::Gem::Version.new(removal)
                   "was removed in Ruby #{removal}"
                 else
                   "is deprecated since Ruby 4.1 and will be removed in Ruby #{removal}"
                 end
          Diagnostic.from_message_loc(
            call,
            rule: RULE_DEPRECATED_RUBY2_KEYWORDS,
            path: path,
            message: "`#{display}' #{tail} (target_ruby: #{stated_ruby.inspect})",
            severity: :warning,
            method_name: display
          )
        end
      end
    end
  end
end
