# frozen_string_literal: true

require "prism"
require_relative "../../type"
require_relative "../key_presence_guard"

module Rigor
  module Inference
    module Narrowing
      # ADR-116 C1 — the emptiness and key-presence predicate analysers: `empty?` / `any?` / `none?` over an
      # array receiver ({.analyse_array_emptiness_predicate}), and `key?` / `has_key?` / `include?` / `member?` /
      # `fetch` over a hash receiver ({.analyse_key_presence_predicate}), with the `HashShape` key promotion and
      # removal they apply. {.static_hash_key} is the literal-key reader `Narrowing`'s `respond_to?` predicate
      # shares.
      #
      # Calls nothing in `Narrowing`; `Narrowing.dispatch_call_simple` and `Narrowing.analyse_respond_to_predicate`
      # are its callers.
      module PresencePredicates
        module_function

        # ADR-47 §4-4 (Elixir `tuple_size`/non-empty analogue) — a bare `arr.empty?` /
        # `arr.any?` / `arr.none?` (no block, no args) narrows an Array-typed receiver to
        # `non-empty-array[T]` on the edge that implies "at least one element":
        #
        #   - `empty?` → false edge   (the array is NOT empty)
        #   - `any?`   → true  edge   (a truthy element exists ⇒ non-empty)
        #   - `none?`  → false edge   (a truthy element exists ⇒ non-empty)
        #
        # The opposite edge is the conservative no-op (`any?`/`none?` falseness does not imply
        # emptiness — the array may hold only falsey elements; `empty?` truth could narrow to an
        # empty array but that carrier move is deferred). Only `Nominal[Array, [T]]` receivers
        # narrow — `Tuple` is already known-length, `Dynamic` is left alone (gradual
        # guarantee), and a non-Array receiver (`String#empty?`, `Range#any?`, …) bails so the
        # existing string / predicate paths still run.
        def analyse_array_emptiness_predicate(node, scope, name)
          return nil if node.block
          return nil unless node.arguments.nil? || node.arguments.arguments.empty?

          reader, writer = emptiness_receiver_accessors(node.receiver)
          return nil if reader.nil?

          current = scope.public_send(reader, node.receiver.name)
          return nil if current.nil?

          non_empty = narrow_to_non_empty_array(current)
          return nil if non_empty.equal?(current) # receiver is not an Array shape → opaque

          non_empty_scope = scope.public_send(writer, node.receiver.name, non_empty)
          name == :any? ? [non_empty_scope, scope] : [scope, non_empty_scope]
        end

        def emptiness_receiver_accessors(receiver)
          case receiver
          when Prism::LocalVariableReadNode then %i[local with_local]
          when Prism::InstanceVariableReadNode then %i[ivar with_ivar]
          else [nil, nil]
          end
        end

        # Refines `Array[T]` (and every Array member of a Union) to `non-empty-array[T]`;
        # returns the input unchanged when nothing applies, so the caller can detect "no
        # narrowing".
        def narrow_to_non_empty_array(type)
          case type
          when Type::Nominal
            return type unless type.class_name == "Array"

            Type::Combinator.non_empty_array(type.type_args.first || Type::Combinator.top)
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_to_non_empty_array(member) })
          else
            type
          end
        end

        # ADR-47 §4-3 (Elixir `is_map_key/2` analogue) — `h.key?(:foo)` narrows the receiver on
        # the truthy edge: a `HashShape` whose `:foo` is an OPTIONAL key has it promoted to
        # REQUIRED, so a subsequent `h[:foo]` reads the declared value type instead of `value |
        # nil` (the optionality nil is gone). Sound because key presence removes only the
        # optionality-injected nil, never the value's own intrinsic nil (`h = {foo: nil}` keeps
        # `h[:foo]` nil-typed). The falsey edge is left unchanged — "key absent" is the
        # conservative no-op. Only literal `Symbol`/`String` arguments and
        # `LocalVariableReadNode`/`InstanceVariableReadNode` receivers narrow; everything else
        # (Dynamic, `Nominal[Hash]`, method-chain receivers) bails to no narrowing. A non-literal
        # key goes to {#analyse_computed_key_presence_predicate} (issue #1703).
        def analyse_key_presence_predicate(node, scope)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          # A literal key promotes a shape's optional key only for `key?` / `has_key?`; `include?` / `member?` reach
          # the computed-key guard alone, so a String or Array receiver's `include?` keeps its own narrowings.
          key = static_hash_key(node.arguments.arguments.first) if %i[key? has_key?].include?(node.name)
          return analyse_computed_key_presence_predicate(node, scope) if key.nil?

          case node.receiver
          when Prism::LocalVariableReadNode
            key_presence_scopes(node.receiver.name, key, scope, reader: :local, writer: :with_local)
          when Prism::InstanceVariableReadNode
            key_presence_scopes(node.receiver.name, key, scope, reader: :ivar, writer: :with_ivar)
          end
        end

        # Issue #1703 — `H.key?(k)` / `has_key?` / `include?` / `member?` with a non-literal key (a local, an ivar,
        # or a reader chain such as `prop.column_type`) on a closed hash shape held in a local, an ivar or a
        # constant. The truthy edge records the guard, and a later `H[k]` of the same receiver and structurally the
        # same key drops the miss `nil` ({KeyPresenceGuard}). The falsey edge is the no-op: an
        # absent computed key says nothing a shape can record. Nil when the guard does not apply, so a collection's
        # `include?` still reaches the membership and String predicates.
        def analyse_computed_key_presence_predicate(node, scope)
          truthy = KeyPresenceGuard.record(node, scope)
          truthy && [truthy, scope]
        end

        def key_presence_scopes(name, key, scope, reader:, writer:)
          current = scope.public_send(reader, name)
          return nil if current.nil?

          truthy = narrow_hash_key_present(current, key)
          # §4-3 false edge — `h.key?(:foo)` being false proves `:foo` is absent, so on that
          # edge `h[:foo]` reads `nil`. Remove the (optional) key from the shape; a required
          # key makes the false edge dead and an unknown key is already nil, both no-ops.
          falsey = narrow_hash_key_absent(current, key)
          return nil if truthy.equal?(current) && falsey.equal?(current) # predicate is opaque

          truthy_scope = truthy.equal?(current) ? scope : scope.public_send(writer, name, truthy)
          falsey_scope = falsey.equal?(current) ? scope : scope.public_send(writer, name, falsey)
          [truthy_scope, falsey_scope]
        end

        def static_hash_key(node)
          case node
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::StringNode then node.unescaped
          end
        end

        # Promotes `key` from optional to required across a HashShape (or every HashShape
        # member of a Union). Returns the input unchanged when nothing applies, so the caller
        # can detect "no narrowing".
        def narrow_hash_key_present(type, key)
          case type
          when Type::HashShape
            promote_hash_key(type, key)
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_hash_key_present(member, key) })
          else
            type
          end
        end

        def promote_hash_key(shape, key)
          return shape unless shape.pairs.key?(key) # unknown key → no value type to assert
          return shape unless shape.optional_key?(key) # already required → nothing to promote

          Type::HashShape.new(
            shape.pairs,
            required_keys: shape.required_keys + [key],
            optional_keys: shape.optional_keys - [key],
            read_only_keys: shape.read_only_keys,
            extra_keys: shape.extra_keys
          )
        end

        # §4-3 false edge — drops `key` from a HashShape (or every HashShape member of a Union)
        # so the proven-absent key reads `nil`. Returns the input unchanged when nothing
        # applies (caller detects "no narrowing"). Only an *optional* present key is removed: a
        # required key makes `key?` always true (the false edge is dead, leave the shape opaque)
        # and a key absent from `pairs` already reads `nil` on a closed shape. On an open shape an
        # undeclared key keeps reading `untyped` on this edge — sound but imprecise, since the shape
        # carries no per-key exclusion to record what the guard just proved absent.
        def narrow_hash_key_absent(type, key)
          case type
          when Type::HashShape
            remove_hash_key(type, key)
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_hash_key_absent(member, key) })
          else
            type
          end
        end

        def remove_hash_key(shape, key)
          return shape unless shape.pairs.key?(key)
          return shape unless shape.optional_key?(key)

          Type::HashShape.new(
            shape.pairs.except(key),
            required_keys: shape.required_keys,
            optional_keys: shape.optional_keys - [key],
            read_only_keys: shape.read_only_keys - [key],
            extra_keys: shape.extra_keys
          )
        end

        private_class_method :emptiness_receiver_accessors, :narrow_to_non_empty_array,
                             :analyse_computed_key_presence_predicate, :key_presence_scopes, :narrow_hash_key_present,
                             :promote_hash_key, :narrow_hash_key_absent, :remove_hash_key
      end
    end
  end
end
