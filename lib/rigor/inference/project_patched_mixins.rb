# frozen_string_literal: true

require "prism"

require_relative "project_patched_methods"
require_relative "../source/constant_path"

module Rigor
  module Inference
    module ProjectPatchedScanner
      # Issue #1708 — the `include` / `prepend` edges a `pre_eval:` file writes, so a module it mixes into an
      # ancestor (`Numeric.include(M)`) answers the receivers below that ancestor through
      # {ProjectPatchedMethods#lookup_through_ancestors}. Ruby 4.0.5: after `Numeric.include(NumExt)`, `1.inc_m` and
      # `1.5.inc_m` run.
      module Mixins
        # An `include` / `prepend` the walk met, with the lexical prefix {.resolve} resolves its module's written
        # name in.
        Pending = Data.define(:owner, :module_name, :kind, :prefix)

        CALLS = %i[include prepend].freeze
        private_constant :CALLS

        module_function

        # The {Pending} edges `node` writes, or none: `Numeric.include(M)` on a constant, or `include M` /
        # `self.include(M)` in a body. A top-level `include M` includes into `Object`, as Ruby's does. One in a
        # `class << self` body is an `extend`, which this does not read; a module argument that is not a constant is
        # skipped.
        def pending(node, qualified_prefix, in_singleton_class)
          return [] unless CALLS.include?(node.name) && node.arguments

          owner = owner(node.receiver, qualified_prefix, in_singleton_class)
          return [] if owner.nil?

          node.arguments.arguments.filter_map do |arg|
            name = Source::ConstantPath.qualified_name_or_nil(arg)
            next if name.nil?

            prefix = arg.is_a?(Prism::ConstantPathNode) && arg.parent.nil? ? [] : qualified_prefix
            Pending.new(owner: owner, module_name: name, kind: node.name, prefix: prefix)
          end
        end

        def owner(receiver, qualified_prefix, in_singleton_class)
          case receiver
          when nil, Prism::SelfNode
            return nil if in_singleton_class
            return "Object" if qualified_prefix.empty? && receiver.nil?

            qualified_prefix.join("::") unless qualified_prefix.empty?
          else
            Source::ConstantPath.qualified_name_or_nil(receiver)
          end
        end
        private_class_method :owner

        # The `include` / `prepend` call an idempotence guard runs only while its module is not yet an ancestor of its
        # receiver, or nil. The guards are `X.include?(M)`, `X.ancestors.include?(M)` and `X < M`, written after the
        # call as `unless` or as `if !`; the guard only skips a second include, so the call is read as a direct
        # statement would be (#2109). The guard names the call's own receiver and module; any other condition, or a
        # guard naming another receiver or module, leaves the call unread.
        #
        # `top_level` says the conditional is a direct statement of the file's top level, where a receiverless call
        # includes into Object; see {guarded_call?}. The `CALLS` check is defensive: the scanner applies a call's mixin
        # edge only when {Mixins.pending} reads it as include or prepend, so a call of another name changes nothing.
        def guarded(node, top_level)
          return nil unless node.is_a?(Prism::UnlessNode) || node.is_a?(Prism::IfNode)

          call = guarded_body(node)
          return nil unless call.is_a?(Prism::CallNode) && CALLS.include?(call.name) && guarded_call?(call, top_level)

          guard = when_undefined(node)
          call if guard && guards?(guard, call)
        end

        # Whether `call` takes exactly one module, and is not receiverless at the file's top level. Such an include's
        # guard would be `include?` on main, which Ruby does not define: the guard raises, so it is not read as an
        # include into Object. A receiverless call in a class or module body names that body's own module.
        def guarded_call?(call, top_level)
          call.arguments&.arguments&.size == 1 && !(top_level && call.receiver.nil?)
        end
        private_class_method :guarded_call?

        # The sole statement of an `unless` or `if` body, or nil when the conditional has an else branch or another
        # body.
        def guarded_body(node)
          return nil if node.is_a?(Prism::UnlessNode) ? node.else_clause : node.subsequent

          body = node.statements&.body
          body.first if body&.size == 1
        end
        private_class_method :guarded_body

        # The predicate the body runs under: `unless P` runs its body when P is false; `if !P` does too.
        def when_undefined(node)
          predicate = unwrap(node.predicate)
          return predicate if node.is_a?(Prism::UnlessNode)
          return nil unless predicate.is_a?(Prism::CallNode) && predicate.name == :! && predicate.receiver

          unwrap(predicate.receiver)
        end
        private_class_method :when_undefined

        def unwrap(node)
          body = node.body.body if node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode)
          body&.size == 1 ? body.first : node
        end
        private_class_method :unwrap

        # Whether `guard` is `X.include?(M)`, `X.ancestors.include?(M)` or `X < M`, where `X` and `M` are the receiver
        # and the argument of `call`; {guarded} passes only a call with exactly one argument.
        def guards?(guard, call)
          return false unless guard.is_a?(Prism::CallNode) && guard.arguments&.arguments&.size == 1

          subject, named = guard_subject(guard)
          named && same_constant?(subject, call.receiver) && same_constant?(named, call.arguments.arguments.first)
        end
        private_class_method :guards?

        # The `[receiver, module]` a guard names, or nil.
        def guard_subject(guard)
          named = guard.arguments.arguments.first
          case guard.name
          when :<
            [guard.receiver, named] if guard.receiver
          when :include?
            receiver = guard.receiver
            if receiver.is_a?(Prism::CallNode) && receiver.name == :ancestors && receiver.arguments.nil?
              [receiver.receiver, named]
            else
              [receiver, named]
            end
          end
        end
        private_class_method :guard_subject

        # Whether two receivers or modules name the same constant; two absent receivers (self) match.
        def same_constant?(left, right)
          return left.nil? && right.nil? if left.nil? || right.nil?

          name = Source::ConstantPath.qualified_name_or_nil(left)
          !name.nil? && name == Source::ConstantPath.qualified_name_or_nil(right)
        end
        private_class_method :same_constant?

        # Each {Pending} edge's module name, resolved as Ruby resolves the constant from where it is written:
        # `include NumExt` in `module Ext` names `Ext::NumExt` when a patch body opens that, else `NumExt`. Only the
        # names the `pre_eval:` files open or mix into are candidates; one they do not name stays as written.
        def resolve(pending, entries)
          known = entries.to_set(&:class_name).merge(pending.map(&:owner))
          pending.map do |item|
            candidates = item.prefix.size.downto(1).map do |depth|
              [*item.prefix.first(depth), item.module_name].join("::")
            end
            name = candidates.find { |candidate| known.include?(candidate) } || item.module_name
            ProjectPatchedMethods::Mixin.new(owner: item.owner, module_name: name, kind: item.kind)
          end
        end
      end
    end
  end
end
