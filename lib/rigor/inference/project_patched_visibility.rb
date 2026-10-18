# frozen_string_literal: true

require "prism"

require_relative "../source/literals"
require_relative "../source/node_children"
require_relative "module_function_state"

module Rigor
  module Inference
    module ProjectPatchedScanner
      # Issue #1708 — the visibility a `pre_eval:` file gives each `def` it writes in a class, module or `class <<`
      # body, so a private patch does not answer a call with an explicit receiver. Ruby 4.0.5:
      # `module Kernel; private def kp = 1; end; 1.kp` raises NoMethodError (private method 'kp' called for an
      # instance of Integer), while a bare `kp` runs.
      #
      # The readings, over each body's direct statements in order:
      #
      # - a bare `private`, `protected`, `public` or `module_function` (receiverless or on `self`) sets the default
      #   for the `def`s after it in that body;
      # - `private def x`, `protected def x`, `public def x`, `module_function def x` set that `def`'s, and
      #   `private_class_method def self.x` / `public_class_method def self.x` a singleton `def`'s;
      # - a `def self.x` is public whatever the default says, as in Ruby;
      # - a `def` nested in a statement (an `if`, a `begin`) takes the default, unless the statement holds a bare
      #   call of its own, which may or may not run: then it and every `def` after it are public, the reading that
      #   answers more calls.
      #
      # A `def` this does not reach (one in a block, a `rescue` clause, or a body nested in a conditional, a block or a
      # method, which may not run) is public. A named call with Symbol arguments (`private :x`) is the scanner's to
      # apply, since it may name a `def` of an earlier file ({.pending}).
      module Visibility
        # The receiverless calls that set an instance `def`'s visibility, and what they set. `module_function` makes
        # the instance method private and adds a public singleton copy.
        INSTANCE_CALLS = {
          private: :private, protected: :protected, public: :public, module_function: :module_function
        }.freeze
        # The calls that set a singleton `def`'s visibility.
        SINGLETON_CALLS = { private_class_method: :private, public_class_method: :public }.freeze

        # The nodes a nested `def` does not take the body's default under: another body, or a block.
        OPAQUE = [
          Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::DefNode, Prism::BlockNode,
          Prism::LambdaNode
        ].freeze
        private_constant :OPAQUE

        # The bodies {.read_body} reads when they are a direct statement of a body it reads.
        BODIES = [Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode].freeze
        private_constant :BODIES

        # A named visibility call (`private :x`, `module_function :x`, `private_class_method :x`) in a body, which
        # {ProjectPatchedScanner.resolve_aliases} applies to the binding its name has when it runs. `visibility` is
        # `:private`, `:protected`, `:public` or `:module_function`.
        Pending = Data.define(:class_name, :names, :kind, :visibility, :source_path, :source_line)

        module_function

        # The {Pending} change a named visibility call in a body makes, or nil. The `def`-argument form
        # (`private def x`) is {.defs}'s; a computed name is skipped, leaving the method public.
        def pending(node, qualified_prefix, in_singleton_class, source_path)
          return nil if qualified_prefix.empty?

          visibility, side = call(node)
          return nil if visibility.nil? || node.arguments.nil?

          names = node.arguments.arguments.filter_map { |arg| Source::Literals.symbol_or_string(arg) }
          return nil if names.empty?

          Pending.new(
            class_name: qualified_prefix.join("::"), names: names,
            kind: side == :singleton || in_singleton_class ? :singleton : :instance, visibility: visibility,
            source_path: source_path, source_line: node.location&.start_line || 1
          )
        end

        # The value {.defs} records for a call written as a direct statement of a body or of the file's top level, the
        # only calls whose named visibility change ({.pending}) or mixin edge ({Mixins.pending}) the scanner applies to
        # the body's class. A call nested in a conditional, a block, a method body or a `Class.new` may not run, or
        # runs on another class, so it changes nothing: the reading that answers more calls.
        STATEMENT = Object.new.freeze

        # @return the visibility of each `def` (by identity) the file's bodies give one other than public:
        #   `:private`, `:protected` or `:module_function`; and {STATEMENT} for each call that is a direct statement.
        def defs(root)
          found = {}.compare_by_identity
          # The file's top level, and through {.read_body} every class, module or `class <<` body written as a direct
          # statement of it or of another body so read: the bodies that run whenever the file loads. A body nested in
          # a conditional, a block or a method may not run, so none of its calls or toggles is read and its `def`s
          # are public.
          read_body(root.statements, found) if root.is_a?(Prism::ProgramNode)
          found
        end

        # Applies a {Pending} change to the binding each of its names has: `bound` maps `[class_name, name, kind]` to
        # that binding and `homes` to the per-file table holding it, which is updated in place, so the change is not a
        # second declaration. A name the class does not bind is one it inherits (`public :kp` in `class Integer` over
        # `module Kernel; private def kp`), which Ruby copies onto the class with the new visibility: `overrides` gets
        # `key => visibility` for {ProjectPatchedMethods#lookup_through_ancestors} to apply to the body it finds farther
        # on. Yields each copy that binds (`module_function :x`'s singleton), at the call's line, for the caller to
        # bind.
        def apply(pending, bound, homes, overrides)
          pending.names.each do |name|
            key = [pending.class_name, name, pending.kind]
            entry = bound[key]
            next overrides[key] = pending.visibility if entry.nil?

            changed, *copies = applied(entry, pending.visibility)
            bound[key] = homes[key][key] = changed
            copies.each { |copy| yield copy.with(source_path: pending.source_path, source_line: pending.source_line) }
          end
        end

        # `entry` as `visibility` leaves it, then any copy that binds: `module_function` makes an instance method
        # private and binds a public singleton copy, as Ruby does.
        def applied(entry, visibility)
          return [entry.with(visibility: visibility)] unless visibility == :module_function

          copies = [entry.with(visibility: :private)]
          copies << entry.with(kind: :singleton, visibility: :public) if entry.kind == :instance
          copies
        end

        # The visibility call `node` is, as `[visibility, side]`, or nil: `side` is `:instance` for the
        # {INSTANCE_CALLS} and `:singleton` for the {SINGLETON_CALLS}.
        def call(node)
          return nil unless node.is_a?(Prism::CallNode)
          return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

          if (visibility = INSTANCE_CALLS[node.name])
            [visibility, :instance]
          elsif (visibility = SINGLETON_CALLS[node.name])
            [visibility, :singleton]
          end
        end

        def read_body(body, found) # rubocop:disable Metrics/PerceivedComplexity
          default = :public
          direct_statements(body).each do |stmt|
            found[stmt] = STATEMENT if stmt.is_a?(Prism::CallNode)
            visibility, side = call(stmt)
            if visibility && ModuleFunctionState.bare?(stmt)
              default = visibility if side == :instance
            elsif visibility
              mark_arguments(stmt, visibility, side, found)
            elsif stmt.is_a?(Prism::DefNode)
              mark(stmt, default, found) if stmt.receiver.nil?
            elsif BODIES.any? { |kind| stmt.is_a?(kind) }
              read_body(stmt.body, found)
            else
              default = :public if bare_call_nested?(stmt)
              mark_nested(stmt, default, found)
            end
          end
        end
        private_class_method :read_body

        def direct_statements(body)
          body = body.statements if body.is_a?(Prism::BeginNode)
          body.is_a?(Prism::StatementsNode) ? body.body : []
        end
        private_class_method :direct_statements

        def mark_arguments(call, visibility, side, found)
          call.arguments&.arguments&.each do |arg|
            next unless arg.is_a?(Prism::DefNode)
            next unless (side == :singleton) == arg.receiver.is_a?(Prism::SelfNode)

            mark(arg, visibility, found)
          end
        end
        private_class_method :mark_arguments

        def mark(def_node, visibility, found)
          found[def_node] = visibility unless visibility == :public
        end
        private_class_method :mark

        def mark_nested(node, default, found)
          return unless node.is_a?(Prism::Node)
          return if OPAQUE.any? { |kind| node.is_a?(kind) } && !node.is_a?(Prism::DefNode)

          if node.is_a?(Prism::DefNode)
            mark(node, default, found) if node.receiver.nil?
            return
          end
          node.rigor_each_child { |child| mark_nested(child, default, found) }
        end
        private_class_method :mark_nested

        def bare_call_nested?(node)
          return false unless node.is_a?(Prism::Node)
          return false if OPAQUE.any? { |kind| node.is_a?(kind) }

          visibility, = call(node)
          return true if visibility && ModuleFunctionState.bare?(node)

          node.compact_child_nodes.any? { |child| bare_call_nested?(child) }
        end
        private_class_method :bare_call_nested?
      end
    end
  end
end
