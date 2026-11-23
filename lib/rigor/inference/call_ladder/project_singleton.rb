# frozen_string_literal: true

require_relative "../../memo_audit"
require_relative "../../type"
require_relative "../singleton_external_ahead"
require_relative "../singleton_hook_decline"
require_relative "../singleton_included_hook"
require_relative "../singleton_object_constant"

module Rigor
  module Inference
    module CallLadder
      # The `project_singleton` rung of the call ladder (ADR-116 WD12): a call on a class object, or on a constant that
      # holds an ordinary object with a `class << Const` body, answered by re-typing the singleton `def` the project
      # wrote, with the call's argument types bound. `ExpressionTyper` asks it behind the user-method rung, in each
      # entry `CallLadder::RUNGS` gives it. {ExpressionTyper} is not required here: it requires this file, and `Scope`
      # is loaded before either.
      #
      # {.try_call} is the rung, asked with the site and the walking typer, and the module's one entry: only the
      # ladder's entries ask it, so it has no second entry. Every other function is private to the module.
      #
      # The module holds no state. It reads the scope as `typer.scope` (never the site's, which `sig/` leaves
      # untyped) and calls back four methods of the typer, the four the user-method rung calls back:
      # `class_graph_buckets`, `positional_correspondence`, `infer_user_method_return` and `degrade_if_overridable`.
      # `CallLadder::PORT` lists them, and `spec/rigor/inference/call_ladder/port_spec.rb` fails a call on the typer
      # that is not one of them. A function that only reads the scope takes it as a parameter and never sees the typer.
      module ProjectSingleton # rubocop:disable Metrics/ModuleLength
        module_function

        # The project-side singleton-method band: a `Foo.bar` call resolved against a `class << …` / `def self.…`
        # body the project itself wrote. Which of the two tiers applies is decided by the receiver carrier —
        # `Singleton[Foo]` when the constant names a class or module, `Nominal[…]` when it holds an ordinary
        # object (#320) — so the two are mutually exclusive and consulting both is one resolution attempt.
        #
        # The rung, asked with the call `site` describes. The method name is the site's, not the call node's: the read
        # of `c[k] += v` is a site whose node is the write and whose name is `[]`.
        def try_call(site, typer)
          receiver = site.receiver
          call_node = site.call_node
          arg_types = site.args
          method_name = site.method_name
          block_type = site.block_type
          try_singleton_method_inference(receiver, call_node, arg_types, method_name, block_type, typer) ||
            try_singleton_object_constant_inference(receiver, call_node, arg_types, method_name, block_type, typer)
        end

        # Module-singleton call resolution (ADR-57 follow-up) — resolves `Foo.<name>` on a `Singleton[Foo]`
        # receiver against `Foo`'s user-side singleton defs (`def self.x`, `def Foo.x`, a `class << self`
        # body, or a `module_function` method) and re-types the body with the call's argument types bound.
        # The body scope's `self_type` is the SAME `Singleton[Foo]` carrier, so an implicit-self call inside
        # (`def self.via; helper(x); end`) re-enters this tier and resolves against the same singleton table
        # — the symmetric counterpart of the instance-side ancestor walk.
        #
        # Issue #731 — resolution walks the SUPERCLASS chain, so a class method a base class defines answers
        # on its subclasses (`class Plain < Base` with `def self.build` on `Base`: `Plain.build` was
        # `Dynamic[top]` while `Plain.new.inst` resolved on the same fixture). Superclasses only, which is the
        # whole shape of class-method inheritance — an `include`d module's `def self.x` is not callable on the
        # includer, and `extend M` is already folded into the extender's own singleton entries by
        # `ScopeIndexer`. A miss still degrades to `Dynamic[top]`, never a false resolution.
        #
        # The OWNER — not the receiver class — is what the overridable gate keys on, exactly as the instance
        # side does: adopting `Base`'s literal return is unsound when a subclass redefines the method, and
        # after this change the resolved body is routinely not the receiver's own.
        def try_singleton_method_inference(receiver, call_node, arg_types, method_name, block_type, typer)
          return nil unless receiver.is_a?(Type::Singleton)

          def_node, owner = resolve_singleton_def_with_owner(receiver.class_name, method_name, typer)
          return nil if def_node.nil?
          # Issue #1936 — a contested slot holds a `def` a later definer may have replaced
          # (`singleton_class.alias_method :x, :y` after `def self.x`), or one that may not have run: its body is not
          # proven to be the method Ruby calls, so the call falls through to `Dynamic`.
          return nil if typer.scope.discovery.contested?(:discovered_singleton_def_nodes, [owner, method_name.to_sym])

          arg_types, positionals_unknown = typer.positional_correspondence(call_node, arg_types)
          result = typer.infer_user_method_return(def_node, receiver, arg_types,
                                                  yield_type: block_type, positionals_unknown: positionals_unknown)
          return result if result.nil?

          typer.degrade_if_overridable(result, owner, method_name, :singleton)
        rescue StandardError
          nil
        end

        # The singleton twin of {ExpressionTyper#resolve_user_def_with_owner}. Memoised in a bucket nested under the
        # SINGLETON def table's identity as well as the class-graph trio: `class_graph_buckets` keys on
        # `discovered_def_nodes` / `discovered_superclasses` / `discovered_includes`, and this walk reads a
        # fourth table those three do not imply. Keying on what the answer actually depends on is the #682
        # lesson — a memo that outlives its inputs serves one scope's answer to another.
        #
        # It is the TYPING read only, so it also withholds (`[nil, nil]`, the call types `Dynamic`) where an external
        # ancestor may answer ahead of the definer found (#1572: `extend M; extend Enumerable` makes `C.to_a`
        # `Enumerable#to_a`, which the reader passes over). The existence reads keep the reader's own answer.
        #
        # The memo is the typer's class-graph slot ({ExpressionTyper#class_graph_buckets}), under its `:singleton_def`
        # bucket.
        def resolve_singleton_def_with_owner(class_name, method_name, typer)
          by_singleton = (typer.class_graph_buckets[:singleton_def] ||= {}.compare_by_identity)
          cache = (by_singleton[typer.scope.discovered_singleton_def_nodes] ||= {})
          table = (cache[class_name.to_s] ||= {})
          key = method_name.to_sym
          if table.key?(key)
            return MemoAudit.check("class graph singleton def", table[key], class_name, key) do
              compute_singleton_def_with_owner(class_name, method_name, typer.scope)
            end
          end

          table[key] = MemoAudit.key_audit("class graph singleton def") do
            compute_singleton_def_with_owner(class_name, method_name, typer.scope)
          end
        end

        def compute_singleton_def_with_owner(class_name, method_name, scope)
          found = scope.singleton_def_through_ancestors(class_name, method_name)
          owner = found.last
          found = [nil, nil] if owner && SingletonExternalAhead.withhold?(scope, class_name, method_name, owner)
          if found.last && dynamic_singleton_definer_ahead?(class_name, method_name, found.last, scope)
            found = [nil, nil]
          end
          found = [nil, nil] if found.last && singleton_hook_order_split?(class_name, method_name, scope)
          found = [nil, nil] if found.last && singleton_mixin_split?(class_name, method_name, found, scope)
          found = [nil, nil] if found.last && unseen_definer_split?(class_name, method_name, found, scope)
          found
        end

        # A definer no def table holds that Ruby may call instead of `found`: a hook-placed one, or a foreign `def C.x`.
        def unseen_definer_split?(class_name, method_name, found, scope)
          hidden_hook_split?(class_name, method_name, found.last, scope) ||
            foreign_definer_behind_copy?(method_name, found, scope)
        end

        # Issue #3155 — a `def C.x` outside C's body (in the extended module, another class or the file) defines C's
        # own `x`, which no def table holds, only its object-singleton mark. A fold copy found on C may then be a
        # body Ruby does not call, so the typing read withholds.
        def foreign_definer_behind_copy?(method_name, found, scope)
          node, owner = found
          return false unless singleton_copy_head(owner, node, scope) != owner

          SingletonHookDecline.foreign_singleton_definer?(scope, owner, method_name)
        end

        # The hook-placed definers a found singleton `def` may not be the one Ruby calls through.
        def hidden_hook_split?(class_name, method_name, owner, scope)
          hidden_hook_definer?(class_name, method_name, owner, scope) ||
            hook_block_rival?(class_name, method_name, owner, scope)
        end

        # Issue #3005 — a class object's own `def self.x` and a `def self.x` a concern's `included` block defines on it
        # replace each other in the order the `def` and the `include` run, which the tables do not hold, so the typing
        # read withholds when the answer is a class object's own `def` and its level's hook-block module defines the
        # name too.
        def hook_block_rival?(class_name, method_name, owner, scope)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          index = chain.entries.index { |entry| !entry.external? && entry.side == :singleton && entry.name == owner }
          !index.nil? && chain.hook_block_rival?(scope, index, method_name)
        end

        # Issue #1592 — a module a hook extends the class with may define the name private (`class_methods do private;
        # def x`), which Ruby refuses on an explicit receiver. The visibility rule does not reach that module, so the
        # typing read withholds rather than answer a call Ruby raises on. A module the class `extend`s itself is left to
        # that rule.
        def hidden_hook_definer?(class_name, method_name, owner, scope)
          visibility = scope.discovered_method_visibility(owner, method_name)
          return false if visibility.nil? || visibility == :public

          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          return false unless chain.entries.any? { |entry| entry.name == owner && entry.side == :instance }

          scope.singleton_extends_of(class_name).none? do |raw|
            written = raw.delete_prefix("::")
            owner == written || owner.end_with?("::#{written}")
          end
        end

        # Issue #1592 — whether to withhold `method_name`'s class-side answer: a class object on the chain has
        # hook-extended modules whose order against its own `extend`s is not a fact, and the orders give different
        # definers (the retro world's against the chain's, or, with no retro world, the class objects' alone against
        # the chain's). A `def` the extends fold copied onto a class object is read where Ruby finds it, at the extended
        # module's own entry, since the copy sits ahead of every module in both orders.
        def singleton_hook_order_split?(class_name, method_name, scope)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          return false unless chain.hook_order_marked?

          answer = positioned_singleton_definer(chain, method_name, scope)
          retro = chain.retro_world
          return answer != positioned_singleton_definer(retro, method_name, scope) if retro

          answer != positioned_singleton_definer(chain, method_name, scope, copies: true)
        end

        # Issues #2998 and #3020 — whether a singleton-side mixin of a class object on the chain may answer ahead of
        # `found`: a named prepend master's order does not place, or a module no table names.
        def singleton_mixin_split?(class_name, method_name, found, scope)
          singleton_prepend_split?(class_name, method_name, found, scope) ||
            unnamed_singleton_mixin_split?(class_name, method_name, scope)
        end

        # Issue #2998 — whether to withhold the class-side answer `found` on a chain whose class objects have
        # singleton-side prepends of their own: master's order, which a chain that does not stand answers, places no
        # such prepend, so its definer may not be the one Ruby's order reaches first. A `def` the extends fold copied
        # onto a class object is compared as its module's. A definer from a prepend region whose order is not a fact
        # is withheld whichever order answers.
        def singleton_prepend_split?(class_name, method_name, found, scope)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          return false unless chain.singleton_prepend_marked?

          answer = positioned_singleton_definer(chain, method_name, scope)
          return true if unordered_prepend_definer?(chain, answer)

          node, owner = found
          head = if scope.singleton_def_for(owner, method_name).equal?(node)
                   singleton_copy_head(owner, node, scope)
                 else
                   owner
                 end
          head != answer
        end

        # Whether `answer` is a module in the prepend region of a class object on the chain whose prepends have no known
        # order: the entries between the start of that class's level and its own entry.
        def unordered_prepend_definer?(chain, answer)
          chain.prepend_order_nodes.any? do |node|
            level = chain.level_classes.index(node)
            next true if level.nil?

            start = chain.level_starts[level]
            own = chain.entries.index { |entry| entry.side == :singleton && entry.name == node }
            next true if own.nil?

            chain.entries[start...own].any? { |entry| entry.name == answer }
          end
        end

        # Issue #3020 — whether to withhold the class-side answer on a chain whose class objects mix a module no table
        # names into their singleton side, which may define the name. A prepend (`class << self; prepend(*MODS)`) sits
        # ahead of the class object's own `def self.`, so a definer at or behind that class object's level is withheld;
        # an `extend(*MODS)` or a `class << self` `include(*MODS)` sits right behind it, so a definer behind the class
        # object's own entry is withheld and its own `def self.` still answers.
        def unnamed_singleton_mixin_split?(class_name, method_name, scope)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          prepends = chain.unnamed_prepend_nodes
          extends = chain.unnamed_extend_nodes
          return false if prepends.empty? && extends.empty?

          answer = positioned_singleton_definer(chain, method_name, scope)
          prepends.any? { |node| !answered_ahead?(chain, answer, level_start_of(chain, node)) } ||
            extends.any? { |node| !answered_ahead?(chain, answer, own_singleton_index(chain, node)&.succ) }
        end

        # Whether `answer` owns an entry before `stop` (nil when the position is unknown: never). A nil `answer` (no
        # class object's own def) owns none.
        def answered_ahead?(chain, answer, stop)
          !stop.nil? && chain.entries[0...stop].any? { |entry| entry.name == answer }
        end

        def level_start_of(chain, node)
          level = chain.level_classes.index(node)
          level && chain.level_starts[level]
        end

        def own_singleton_index(chain, node)
          chain.entries.index { |entry| entry.side == :singleton && entry.name == node }
        end

        # The owner of the first `def` of the name along the chain: a fold copy is skipped, or with `copies:` read as
        # its module's, on the class objects alone (the answer master gives).
        def positioned_singleton_definer(chain, method_name, scope, copies: false)
          chain.search(scope, side: copies ? :singleton : nil) do |entry|
            next if entry.external?

            name = entry.name
            if entry.side == :singleton
              node = scope.singleton_def_for(name, method_name)
              next nil if node.nil?

              head = singleton_copy_head(name, node, scope)
              copies ? head : (name if head == name)
            elsif scope.user_def_for(name, method_name)
              name
            end
          end
        end

        # The module a receiverless singleton `def` was written in when the extends fold copied it onto `owner`, else
        # `owner`.
        def singleton_copy_head(owner, node, scope)
          head = node.receiver.nil? ? scope.discovery.recorded_def_nesting(node)&.first : nil
          head.nil? ? owner : head
        end

        SINGLETON_WILDCARD_SLOT = %i[singleton *].freeze
        private_constant :SINGLETON_WILDCARD_SLOT

        # Issue #2284 — a project entry nearer than the `def`'s owner on the singleton chain may define the name
        # without a `def`, which the def tables do not hold: `class S < B; define_singleton_method(:x) { "s" }; end`
        # calls S's block, not `B.x`. The farther `def` is then withheld and the call types `Dynamic`. A class's own
        # singleton side is read from the visibility-contest census: `define_singleton_method(:x)`,
        # `singleton_class.define_method(:x)` / `attr_*` and a computed name contest the entry's slot whether or not a
        # `def` is recorded (#1984, #2013). An `extend`ed module's side is read from `discovered_methods`, which holds
        # its `attr_*` and `define_method` rows, and the module's `def self.extended` hook may define any name on the
        # extender, so it withholds too.
        #
        # An `inherited` hook anywhere on the chain past the receiver's own entry runs when the receiver's class is
        # created and may define any singleton method on it (`def self.inherited(s) = s.define_singleton_method(:x)`),
        # so a `def` the receiver only inherits is withheld then as well: a class's `def self.inherited`, or an
        # `inherited` an extended module defines.
        def dynamic_singleton_definer_ahead?(class_name, method_name, owner, scope)
          name = method_name.to_sym
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          return true if SingletonIncludedHook.ahead?(chain, owner.to_s, scope) ||
                         (class_name.to_s != owner.to_s && inherited_hook_on_chain?(chain, class_name.to_s, scope))

          chain.entries.each do |entry|
            next if entry.external?
            return false if entry.name == owner.to_s
            return true if entry_defines_without_def?(entry, name, scope)
            # Issue #1592 — a hook of a module the class includes may have extended it with a module no table names.
            return true if entry.side == :singleton && chain.hook_open_nodes.include?(entry.name)
          end
          false
        end

        def inherited_hook_on_chain?(chain, receiver_name, scope)
          chain.entries.any? do |entry|
            next false if entry.external? || entry.name == receiver_name

            if entry.side == :singleton
              !scope.singleton_def_for(entry.name, :inherited).nil?
            else
              scope.discovered_method?(entry.name, :inherited, :instance)
            end
          end
        end

        def entry_defines_without_def?(entry, name, scope)
          unless entry.side == :singleton
            return scope.discovered_method?(entry.name, name, :instance) ||
                   !scope.singleton_def_for(entry.name, :extended).nil?
          end

          discovery = scope.discovery
          # No edge of its own: `singleton_def_through_ancestors`' chain search filed every entry ahead of the owner.
          discovery.contested?(:discovered_method_visibilities, [entry.name, [:singleton, name]]) ||
            discovery.contested?(:discovered_method_visibilities, [entry.name, SINGLETON_WILDCARD_SLOT])
        end

        # #320 — resolves a call whose receiver is a constant holding an ordinary object with a `class << Const`
        # singleton body, re-typing that body with the call's argument types bound. `self` inside the body IS
        # that object, so the receiver carrier is passed through unchanged. Own-constant only, and only for a
        # name the project actually recorded — a miss degrades to today's `Dynamic[top]`, never a false
        # resolution. `Singleton` receivers never reach here: {.try_singleton_method_inference} owns them.
        def try_singleton_object_constant_inference(receiver, call_node, arg_types, method_name, block_type, typer)
          return nil unless receiver.is_a?(Type::Nominal)

          def_node = SingletonObjectConstant.def_node_for(call_node, receiver, method_name, typer.scope)
          return nil if def_node.nil?

          arg_types, positionals_unknown = typer.positional_correspondence(call_node, arg_types)
          typer.infer_user_method_return(def_node, receiver, arg_types,
                                         yield_type: block_type, positionals_unknown: positionals_unknown)
        rescue StandardError
          nil
        end

        private_class_method :try_singleton_method_inference, :resolve_singleton_def_with_owner,
                             :compute_singleton_def_with_owner, :unseen_definer_split?, :foreign_definer_behind_copy?,
                             :hidden_hook_split?, :hook_block_rival?, :hidden_hook_definer?,
                             :singleton_hook_order_split?, :singleton_mixin_split?, :singleton_prepend_split?,
                             :unordered_prepend_definer?, :unnamed_singleton_mixin_split?, :answered_ahead?,
                             :level_start_of, :own_singleton_index, :positioned_singleton_definer,
                             :singleton_copy_head, :dynamic_singleton_definer_ahead?, :inherited_hook_on_chain?,
                             :entry_defines_without_def?, :try_singleton_object_constant_inference
      end
    end
  end
end
