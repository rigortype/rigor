# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../census_foreign_block"
require_relative "../declaration_walk/rules"
require_relative "../define_method_block_self"
require_relative "../error_info"
require_relative "../hash_lookup_mutation"
require_relative "../index_write_widening"
require_relative "../macro_block_self_type"
require_relative "../method_dispatcher"
require_relative "../multi_target_binder"
require_relative "../mutation_widening"
require_relative "../narrowing"
require_relative "../receiver_writer_call"
require_relative "../reflective_ivar_write"
require_relative "../set_mutation"
require_relative "../string_mutation"
require_relative "census_scope"
require_relative "constant_ivar_value"
require_relative "declared_ivar_types"
require_relative "declared_param_writes"
require_relative "empty_seed"
require_relative "ivar_contributions"

module Rigor
  module Inference
    module ScopeIndexer
      # The class ivar index of one file (slice 7 phase 2, ADR-58), moved out of `scope_indexer.rb` whole (ADR-116
      # WD9, #3400): per class, the type each instance variable holds, joined over the writes the file makes.
      # {.build_class_ivar_index} is the entry, which `ScopeIndexer.index` calls once. It walks every class and
      # module body and types each write's rvalue with no local bound; then it widens the entries for the mutations
      # the file observes, adds the read-before-write `nil`, and joins what other files and the ancestor chain
      # contribute ({IvarContributions}) and what a signature declares ({DeclaredIvarTypes}). The other 98 functions
      # are private: the walk with its arms, the collectors of each kind of body, the recording steps, the held
      # `&&=` and `op=` writes, the censuses of the mutations and of the ivars a method hands back, and the
      # definite-assignment summary that finds a transient `@x = nil` ({.dead_transient_nil_writes}), with the
      # per-class table of instance `def`s it reads ({.collect_class_method_defs}), which no other file of `lib/`
      # calls and the specs reach through `send`.
      #
      # It asks {DeclarationWalk::Rules} for each declaration context and {CensusScope}, at four sites, for the scope
      # a body's rvalues are typed under. It calls four functions left in `scope_indexer.rb`, recognisers the other
      # walkers ask too, at one site each: `ScopeIndexer.def_side`, `def_receiver_targets_lexical_self?`,
      # `each_attr_macro_name` and `attr_macro`. Seventeen constants moved with it, the ones only it read in that
      # file. Four are public: {IVAR_BARRIER_NODES} and {BindingTargets}, which {ClassCvarCensus} reads by a path
      # where it read the indexer's private names lexically, and {MethodEffectResolver} and {ATTR_WRITER_MACROS},
      # public as they were. It reads `ScopeIndexer::INSTANCE_EVAL_CALLS` lexically, as {NodePropagation} reads the
      # indexer's constants: other rows of `scope_indexer.rb` read it.
      #
      # `scope_indexer.rb` requires this file, and this file does not require it back. It requires the file of what
      # else it names, the dispatcher among them and so the `rbs` gem. So the file loads alone, and until
      # `scope_indexer.rb` has loaded the entry answers only for a program with no call outside a `def` and no
      # `def` with a body inside a class or module: such a `def` is a `NoMethodError` (`def_side`), a call one too
      # (`attr_macro`), and the block of an eval-family call a `NameError` (`INSTANCE_EVAL_CALLS`).
      module ClassIvarIndex # rubocop:disable Metrics/ModuleLength
        module_function

        # Slice 7 phase 2. Builds the class-level ivar accumulator by walking every `Prism::ClassNode` /
        # `Prism::ModuleNode` body, descending into each nested `Prism::DefNode`, and typing every
        # `Prism::InstanceVariableWriteNode` rvalue under a scope that carries the appropriate `self_type` for that def
        # (singleton vs instance). The rvalue is typed with NO local bindings — the pre-pass lacks statement-level
        # threading — so `@x = 1` records `Constant[1]` but `@x = some_local + 1` records `Dynamic[Top]` (since
        # `some_local` is unbound at pre-pass time). Multiple writes to the same ivar union via
        # `Type::Combinator.union`.
        def build_class_ivar_index(root, default_scope, declared_ivar_types: true)
          accumulator = {}
          mutated_ivars = {}
          read_before_write = {}
          init_writes = {}
          # WD3 — per class, then per method, the ivars the method definitely assigns non-nil on every completing path,
          # consulted by `dead_transient_nil_writes` so a ctor that reassigns `@x` indirectly through an unconditional
          # same-class method call (`mask!`) credits the overwrite. Built once per program here, memoised by class.
          method_assign_effects = build_method_assign_effects(root)
          # #2291 — an `@x = LIT` write reads the file's constant table, built on the first such write.
          accumulator[CONSTANT_IVAR_VALUES] = ConstantIvarValue.new(root, default_scope)
          walk_class_ivars(root, [], default_scope, accumulator, mutated_ivars,
                           read_before_write, init_writes, method_assign_effects)
          accumulator.delete(CONSTANT_IVAR_VALUES)
          reflective_opaque = accumulator.delete(REFLECTIVE_OPAQUE_CLASSES)
          singleton_writes = accumulator.delete(SINGLETON_IVAR_WRITES)
          exempt_class_body_writes!(init_writes, accumulator.delete(DEFINE_METHOD_WRITES) || {})
          merge_held_ivar_writes!(accumulator)
          record_aliased_ivar_mutations!(root, mutated_ivars)
          widen_mutated_ivar_entries!(accumulator, mutated_ivars)
          # #2170 — an ancestor's writes as this file's census types them, before its read-before-write `nil`.
          writes = instance_side_writes(accumulator, singleton_writes)
          contribute_read_before_write_nil!(accumulator, read_before_write, init_writes)
          make_reflective_classes_gradual!(accumulator, reflective_opaque)
          # #2079 / #2170 — another file's writes, and the chain's modules' and superclasses', join existing entries.
          IvarContributions.join!(accumulator, writes, default_scope)
          # An in-place mutation the file observes widens a joined value too (a same-file ancestor's String literal).
          widen_mutated_ivar_entries!(accumulator, mutated_ivars)
          # #1406 — an RBS `@x: T` or `attr_* x: T` declaration replaces the census's join of the writes.
          DeclaredIvarTypes.apply!(accumulator, default_scope) if declared_ivar_types
          accumulator.transform_values(&:freeze).freeze
        end

        # #2170 — a copy of the census entries for {IvarContributions} to join as an ancestor's own. #2931 — an ivar a
        # singleton-side `def` of the class writes is left out: its entry joins that write, which runs on the module or
        # class object and never on an includer's instance, so the join reads the file's instance-side census entries
        # for it, as another file's reader does.
        def instance_side_writes(accumulator, singleton_writes)
          accumulator.to_h do |class_name, entries|
            skipped = singleton_writes&.[](class_name)
            [class_name, skipped ? entries.except(*skipped) : entries.dup]
          end
        end

        # Folds the class-body writes {.collect_class_body_ivar_writes} held under {CLASS_BODY_WRITES} into the
        # `init_writes` exemption, except for an ivar a `define_method` block, or a `block_as_methods:` block bound to
        # the receiver's instance ({.method_body_block_call?}), of the class writes (#1768). Such an ivar had no census
        # entry before the block's writes were counted, so the exemption never applied to it; a class-body `@x = nil`
        # writes the class object's ivar and says nothing about whether an instance's `@x` is set, and exempting it
        # would seed `@x` non-nil from the block's write alone (`if @x` folding always-truthy on an instance whose `@x`
        # is unset). It keeps the read-before-write `nil` instead, which only widens.
        def exempt_class_body_writes!(init_writes, define_method_writes)
          (init_writes.delete(CLASS_BODY_WRITES) || {}).each do |class_name, ivars|
            kept = ivars - (define_method_writes[class_name] || EMPTY_GUARDED_IVARS)
            (init_writes[class_name] ||= Set.new).merge(kept)
          end
        end

        # B2.3 — finalize the read-before-write nil contribution. For each class, for each ivar where SOME method body
        # observed a read-before-write AND no `initialize` write exists for that ivar, contribute `Constant[nil]` to the
        # class-wide accumulator.
        #
        # The `initialize` filter is the soundness gate: Ruby semantics guarantee `initialize` runs first (via
        # `Class.new`), so a write there reaches every other method body's read. Read-before-write in a non-init method
        # is then NOT a nil-at-runtime case — it's just AST-order coincidence. Without this filter a normal
        # `def initialize; @x = ... end` / `def use; @x.foo end` class would have `@x` widened with nil, producing FPs
        # at every `@x.foo` call.
        def contribute_read_before_write_nil!(accumulator, read_before_write, init_writes)
          nil_t = Type::Combinator.constant_of(nil)
          read_before_write.each do |class_name, ivar_set|
            init_set = init_writes[class_name] || EMPTY_GUARDED_IVARS
            per_class = accumulator[class_name]
            next if per_class.nil?

            ivar_set.each do |ivar_name|
              # Soundness gates (in order): (1) `initialize` writes the ivar → it's set
              #     before any other method runs, so the
              #     read-before-write in a sibling method is
              #     NOT a runtime nil case.
              # (2) The accumulator has NO entry for the ivar
              #     → some write was deliberately skipped (the
              #     falsey-default `@x = nil unless @x` slice's
              #     no-seed behaviour). Adding nil here would
              #     defeat that skip and re-introduce the
              #     `Constant[nil]` FP the skip silenced.
              next if init_set.include?(ivar_name)
              next unless per_class.key?(ivar_name)

              existing = per_class[ivar_name]
              per_class[ivar_name] = Type::Combinator.union(existing, nil_t)
            end
          end
        end

        # An ivar a method RETURNS leaves the object, and every mutation of the returned reference mutates the ivar:
        # `(bucket_for(entry)[key] ||= {})[name] = row` fills whichever of `@self_rows` / `@path_rows` / `@result_rows`
        # `bucket_for` handed back. {record_ivar_mutator_call} cannot see it — the mutation's receiver is a `CallNode`,
        # not an `InstanceVariableReadNode` — so those ivars kept the empty `HashShape` their `initialize` gave them and
        # `@path_rows.empty?` folded to `Constant[true]` on a hash the class fills. Rigor's own
        # `lib/rigor/effects/plugin_facts.rb` is the worked site.
        #
        # Scope is deliberately narrow: the mutation receiver must be a SELF-call (an explicit receiver is a different
        # object), the callee must be an instance method of the same class, and only ivars in the callee's RETURN
        # position count — an ivar merely read in its body (`@rows[owner]` returns the value, not the hash) does not
        # escape. Over-recording here would widen a shape carrier that nothing mutates, which costs precision on every
        # reader in the class.
        #
        # Runs after the main walk so the returned-ivar summary is complete regardless of definition order, and gated on
        # a class actually having a returning method — the common class contributes nothing and pays one `defs` lookup.
        def record_aliased_ivar_mutations!(root, mutated_ivars)
          defs = collect_class_method_defs(root)
          returned = returned_ivars_by_method(defs)
          return if returned.empty?

          defs.each do |class_name, methods|
            per_class = returned[class_name]
            next if per_class.nil?

            methods.each_value do |def_node|
              gather_aliased_mutations(def_node.body, class_name, per_class, mutated_ivars)
            end
          end
        end

        # Per class, then per method, the ivars each method hands back, dropping the empty sets so the caller's
        # `next if per_class.nil?` skips a whole class in one lookup.
        def returned_ivars_by_method(defs)
          defs.each_with_object({}) do |(class_name, methods), acc|
            methods.each do |method_name, def_node|
              ivars = returned_ivars(def_node)
              (acc[class_name] ||= {})[method_name] = ivars unless ivars.empty?
            end
          end
        end

        # The ivars `def_node` can hand back: an explicit `return @x` anywhere in the body, and the body's tail
        # expression when it is (or resolves through branch nodes to) a bare ivar read. A tail that computes something
        # FROM an ivar (`@rows[k]`, `@rows.dup`) hands back a different object and is not an escape.
        def returned_ivars(def_node)
          body = def_node.body
          return EMPTY_IVAR_SET if body.nil?

          found = Set.new
          collect_explicit_return_ivars(body, found)
          tail_value_nodes(body).each { |node| found << node.name if node.is_a?(Prism::InstanceVariableReadNode) }
          found
        end

        def collect_explicit_return_ivars(node, found)
          return unless node.is_a?(Prism::Node)
          return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          if node.is_a?(Prism::ReturnNode)
            args = node.arguments&.arguments
            found << args.first.name if args && args.size == 1 && args.first.is_a?(Prism::InstanceVariableReadNode)
          end

          node.rigor_each_child { |c| collect_explicit_return_ivars(c, found) }
        end

        # The expressions a body can evaluate to, resolving through the branch nodes whose value is a sub-expression.
        # Depth-capped for the same reason every other walk here is: a pathologically nested tail is not worth unbounded
        # recursion, and stopping early only under-collects (fewer escapes recorded, never more).
        def tail_value_nodes(node, depth = 0)
          return [] unless node.is_a?(Prism::Node)
          return [] if depth >= TAIL_VALUE_DEPTH_CAP

          children = tail_value_children(node)
          return [node] if children.nil?

          children.flat_map { |child| tail_value_nodes(child, depth + 1) }
        end

        # The children a node's own value comes from, or nil when the node IS the value. Split out from
        # {tail_value_nodes} so the recursion stays one line and this stays a lookup table.
        def tail_value_children(node)
          case node
          when Prism::StatementsNode then [node.body.last]
          when Prism::ParenthesesNode then [node.body]
          when Prism::BeginNode, Prism::ElseNode, Prism::WhenNode, Prism::InNode then [node.statements]
          when Prism::IfNode then [node.statements, node.subsequent]
          when Prism::UnlessNode then [node.statements, node.else_clause]
          when Prism::CaseNode then node.conditions + [node.else_clause]
          when Prism::OrNode, Prism::AndNode then [node.left, node.right]
          end
        end

        # Records every mutation in `node` whose receiver is a self-call to one of `per_class`'s returning methods.
        def gather_aliased_mutations(node, class_name, per_class, mutated_ivars)
          return unless node.is_a?(Prism::Node)

          mutator, receiver = mutation_target(node)
          escaped_ivars_for_receiver(receiver, per_class)&.each do |ivar_name|
            per_ivar = ((mutated_ivars[class_name] ||= {})[ivar_name] ||= Set.new)
            per_ivar << mutator
          end

          node.rigor_each_child { |c| gather_aliased_mutations(c, class_name, per_class, mutated_ivars) }
        end

        # The ivars a mutation receiver can be, when the receiver is a same-class self-call. Nil for every other shape.
        def escaped_ivars_for_receiver(receiver, per_class)
          return nil unless receiver.is_a?(Prism::CallNode) && receiver.receiver.nil?

          per_class[receiver.name]
        end

        # Walks the post-collected accumulator and widens any Tuple / HashShape / String-literal entry for an ivar that
        # observed a mutator call anywhere in the same class body. The mutation evidence comes from `gather_ivar_writes`
        # recording every `@ivar.<method>(...)` call whose method is in `MutationWidening::SHAPE_MUTATORS`.
        #
        # The widening uses `MutationWidening.widen_for_mutator` — the same primitive
        # `Inference::StatementEvaluator#eval_call` applies for per-method-body widening on a local / ivar receiver. The
        # class-level pass extends that primitive's reach so a `Tuple`-seeded ivar in `initialize` is observed as
        # `Nominal[Array]` at the entry of every OTHER method body in the class — closing the cross-method gap
        # (Redmine 6.1.2 `Redmine::Views::Builders::Structure` is the canonical worked site).
        #
        # Always-safe: the widening can only LOSE precision; the underlying nominal (`Array` / `Hash`) and the element
        # union are preserved.
        def widen_mutated_ivar_entries!(accumulator, mutated_ivars)
          accumulator.each do |class_name, ivars|
            observed = mutated_ivars[class_name]
            next if observed.nil? || observed.empty?

            ivars.each do |ivar_name, type|
              methods = observed[ivar_name]
              next if methods.nil? || methods.empty?

              ivars[ivar_name] = widen_type_for_observed_mutators(type, methods)
            end
          end
        end

        # Walks a class-ivar accumulator entry (which may be a `Union` of multiple write rvalues) and widens any
        # `Tuple`, `HashShape` or String-valued `Constant` member whose corresponding mutator family was observed
        # against the ivar somewhere in the class.
        # Class-level widening is more aggressive than the per-method-body `MutationWidening` primitive: it widens both
        # the SHAPE carrier (Tuple → Array, HashShape → Hash) AND the element types to `Dynamic[Top]`. The justification
        # — once any method mutates the ivar, its post-mutation contents are statically unknown across method
        # boundaries, so preserving the seed-write's element precision would be an unsound over-claim (e.g.
        # `@struct = [{}]; somewhere: @struct << []` makes the next read's element no longer `Constant[{}]`).
        def widen_type_for_observed_mutators(type, observed_methods)
          members = type.is_a?(Type::Union) ? type.members : [type]
          widened = members.map { |m| widen_member_for_observed_mutators(m, observed_methods) }
          Type::Combinator.union(*widened)
        end

        def widen_member_for_observed_mutators(member, observed_methods)
          case member
          when Type::Tuple
            return member unless observed_methods.any? { |m| MutationWidening::ARRAY_MUTATORS.include?(m) }

            Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])
          when Type::HashShape
            if observed_methods.any? { |m| MutationWidening::HASH_MUTATORS.include?(m) }
              return Type::Combinator.nominal_of("Hash",
                                                 type_args: [Type::Combinator.untyped, Type::Combinator.untyped])
            end

            widen_member_for_lookup_mutators(member, observed_methods)
          when Type::Constant then widen_constant_for_observed_mutators(member, observed_methods)
          else
            member
          end
        end

        # `@s = +"ab"` in one method and `@s << "c"` in another: without this arm the seed stayed pinned at every other
        # method's entry, and `@s == "ab"` folded always-truthy on a receiver that holds `"abc"`. A constant-folded Set
        # (`@s = Set["a"]`, then `@s.clear; @s << 1` elsewhere — issue #2294) takes the untyped floor the Tuple arm
        # takes.
        def widen_constant_for_observed_mutators(member, observed_methods)
          if SetMutation.constant?(member)
            return member unless observed_methods.any? { |m| SetMutation::MUTATORS.include?(m) }

            return Type::Combinator.nominal_of("Set", type_args: [Type::Combinator.untyped])
          end
          return member unless StringMutation.constant?(member) &&
                               observed_methods.any? { |m| StringMutation::MUTATORS.include?(m) }

          Type::Combinator.nominal_of("String")
        end

        # A `HashShape` ivar seed some method gave a default, a default proc or identity keys, and no method stored
        # into, removed from or rewrote: its pairs are the seed's own, so it takes the per-method {HashLookupMutation}
        # widening rather than the untyped floor above — a present key keeps its value across methods, a missing one
        # stops reading `nil`.
        def widen_member_for_lookup_mutators(member, observed_methods)
          observed_methods.reduce(member) do |acc, method_name|
            next acc unless acc.is_a?(Type::HashShape)

            HashLookupMutation.widen_shape(acc, method_name) || acc
          end
        end

        # `def_owner` names the class a `def` leaf belongs to when `self` is rebound — a
        # meta-new block's class — while `qualified_prefix` stays the lexical cref the
        # whole time (`Module.nesting` never rebinds in a block). `[]` marks a self no
        # name covers (anonymous factory, `class <<` body), where def-keyed facts decline.
        def walk_class_ivars(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                             read_before_write = nil, init_writes = nil, method_assign_effects = nil,
                             def_owner: nil, singleton_cref: false, defs_singleton: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            walk_ivars_declaration(node, qualified_prefix, default_scope, accumulator,
                                   mutated_ivars, read_before_write, init_writes,
                                   method_assign_effects, def_owner, singleton_cref)
            return
          when Prism::SingletonClassNode
            return walk_singleton_class_ivars(node, qualified_prefix, default_scope, accumulator,
                                              mutated_ivars, read_before_write, init_writes,
                                              method_assign_effects, def_owner, singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
               Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode,
               Prism::DefNode, Prism::CallNode
            return if walk_ivars_leaf?(node, qualified_prefix, default_scope, accumulator,
                                       mutated_ivars, read_before_write, init_writes,
                                       method_assign_effects, def_owner, singleton_cref,
                                       defs_singleton: defs_singleton)
          end

          node.rigor_each_child do |child|
            walk_class_ivars(child, qualified_prefix, default_scope, accumulator,
                             mutated_ivars, read_before_write, init_writes, method_assign_effects,
                             def_owner: def_owner, singleton_cref: singleton_cref,
                             defs_singleton: defs_singleton)
          end
        end

        # The leaf arms of {.walk_class_ivars}: a `def` collects and stops, a recognised
        # meta-new write or anonymous factory call consumes its own block, and an ordinary
        # call seeds the ADR-38 initializer writes and an `attr_writer` family macro its ivar
        # writes before the ordinary child descent runs.
        # Returns true when the node — and where relevant its block — was consumed.
        def walk_ivars_leaf?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                             read_before_write, init_writes, method_assign_effects,
                             def_owner, singleton_cref, defs_singleton: false)
          case node
          when Prism::DefNode
            collect_def_ivar_writes(node, def_owner || qualified_prefix, default_scope, accumulator,
                                    mutated_ivars, read_before_write, init_writes,
                                    method_assign_effects, singleton_self: defs_singleton)
            true
          when Prism::CallNode
            return true if walk_ivars_meta_call?(node, qualified_prefix, default_scope, accumulator,
                                                 mutated_ivars, read_before_write, init_writes,
                                                 method_assign_effects, def_owner, singleton_cref,
                                                 defs_singleton: defs_singleton)
            return true if walk_ivars_eval_call?(node, qualified_prefix, default_scope, accumulator,
                                                 mutated_ivars, read_before_write, init_writes,
                                                 method_assign_effects, def_owner, singleton_cref,
                                                 defs_singleton: defs_singleton)

            owner = def_owner || qualified_prefix
            collect_initializer_block_ivars(node, owner, default_scope, accumulator, mutated_ivars, init_writes)
            if ATTR_WRITER_MACROS.include?(ScopeIndexer.attr_macro(node))
              record_attr_writer_ivars(node, owner, accumulator)
            end
            collect_define_method_block_ivars(node, owner, default_scope, accumulator, mutated_ivars)
            collect_receiver_writer_ivars(node, owner, qualified_prefix, default_scope, accumulator, mutated_ivars)
            false
          else
            walk_ivars_meta_new?(node, qualified_prefix, default_scope, accumulator,
                                 mutated_ivars, read_before_write, init_writes,
                                 method_assign_effects, def_owner, singleton_cref)
          end
        end

        # The `K = Class.new { … }` arm of {.walk_class_ivars}: the factory call's receiver and
        # arguments keep the enclosing context; the block's `def`-keyed facts belong to the
        # class the write names while its declarations stay lexical.
        def walk_ivars_meta_new?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                 read_before_write, init_writes, method_assign_effects,
                                 def_owner, singleton_cref, defs_singleton: false)
          split = DeclarationWalk::Rules.meta_new_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_class_ivars(part, qualified_prefix, default_scope, accumulator,
                             mutated_ivars, read_before_write, init_writes, method_assign_effects,
                             def_owner: def_owner, singleton_cref: singleton_cref,
                             defs_singleton: defs_singleton)
          end
          if body
            walk_class_ivars(body, qualified_prefix, default_scope, accumulator,
                             mutated_ivars, read_before_write, init_writes, method_assign_effects,
                             def_owner: body_self, singleton_cref: singleton_cref)
          end
          true
        end

        # The bare `Class.new { … }`-family call arm of {.walk_class_ivars}: the block's class
        # has no name, so its `def`-keyed ivar facts walk ownerless rather than under the
        # enclosing class. Returns whether an anonymous factory block was walked.
        def walk_ivars_meta_call?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                  read_before_write, init_writes, method_assign_effects,
                                  def_owner, singleton_cref, defs_singleton: false)
          return false unless DeclarationWalk::Rules.meta_new_constant_rvalue?(node) &&
                              node.block.is_a?(Prism::BlockNode)

          [node.receiver, *node.arguments&.arguments.to_a].compact.each do |part|
            walk_class_ivars(part, qualified_prefix, default_scope, accumulator,
                             mutated_ivars, read_before_write, init_writes, method_assign_effects,
                             def_owner: def_owner, singleton_cref: singleton_cref,
                             defs_singleton: defs_singleton)
          end
          if (body = node.block.body)
            walk_class_ivars(body, qualified_prefix, default_scope, accumulator,
                             mutated_ivars, read_before_write, init_writes, method_assign_effects,
                             def_owner: [], singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm of {.walk_class_ivars}: `def`-keyed ivar facts belong to the
        # receiver's class for `class_eval`, and to the receiver's singleton self for
        # `instance_eval` (`defs_singleton` — `X.instance_eval { def m; @x = 1 }` writes
        # `X`'s own `@x`, typed `singleton(X)` the way `def self.m` is). `self::`
        # declarations anchor on the receiver the same way.
        def walk_ivars_eval_call?(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                  read_before_write, init_writes, method_assign_effects,
                                  def_owner, singleton_cref, defs_singleton: false)
          split = DeclarationWalk::Rules.eval_block_split(node, qualified_prefix, def_owner, singleton_cref)
          return false unless split

          enclosing, body, body_self = split
          enclosing.each do |part|
            walk_class_ivars(part, qualified_prefix, default_scope, accumulator,
                             mutated_ivars, read_before_write, init_writes, method_assign_effects,
                             def_owner: def_owner, singleton_cref: singleton_cref,
                             defs_singleton: defs_singleton)
          end
          if body
            walk_class_ivars(body, qualified_prefix, default_scope, accumulator,
                             mutated_ivars, read_before_write, init_writes, method_assign_effects,
                             def_owner: body_self, singleton_cref: singleton_cref,
                             defs_singleton: INSTANCE_EVAL_CALLS.include?(node.name))
          end
          true
        end

        # The `class <<` arm of {.walk_class_ivars}: the expression evaluates in the enclosing
        # cref — `class << (class D; self; end)` still names `C::D` — while the body's cref is
        # the unnameable singleton class; the marker lifts only at a nameable header.
        def walk_singleton_class_ivars(node, qualified_prefix, default_scope, accumulator, # rubocop:disable Metrics/ParameterLists
                                       mutated_ivars, read_before_write, init_writes,
                                       method_assign_effects, def_owner, singleton_cref)
          walk_class_ivars(node.expression, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: def_owner, singleton_cref: singleton_cref)
          return unless node.body

          # A `def` below `class <<` is a singleton method — its `@x` writes are the class
          # object's own ivars, not instance-ivar facts, so the body walks ownerless.
          walk_class_ivars(node.body, qualified_prefix, default_scope, accumulator,
                           mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           def_owner: [], singleton_cref: true)
        end

        # The declaration arm of {.walk_class_ivars}. Class-body level `@x = nil` writes don't
        # initialise instance ivars at runtime (the class's own singleton ivars and the instance's
        # ivars are separate stores), but they signal "the author KNOWS @x could be nil" and extend
        # the B2.3 soundness gate: an ivar with a class-body write is exempted from the
        # read-before-write nil contribution because the seed already reflects the author's
        # acknowledged nullability via the def-body writes' union. Without this exemption, code that
        # explicitly `@x = nil`s at class-body level then writes `@x = SomeClass.new` inside an
        # instance method gains an unjustified nil widening at every read. Under an unnameable cref
        # a bare/`self::` header opens `#<singleton>::Name` — the write census is skipped and the body
        # walks ownerless; nameable headers re-anchor at a real cref.
        def walk_ivars_declaration(node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                   read_before_write, init_writes, method_assign_effects, def_owner, singleton_cref)
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, def_owner)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return unless child_prefix && node.body

          child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
          collect_class_body_ivar_writes(node.body, child_prefix.join("::"), init_writes) if init_writes && !child_cref
          walk_class_ivars(node.body, child_cref ? [] : child_prefix,
                           DeclarationWalk::Rules.scope_entering_declaration(default_scope, node.constant_path),
                           accumulator, mutated_ivars, read_before_write, init_writes, method_assign_effects,
                           singleton_cref: child_cref)
        end

        def collect_def_ivar_writes(def_node, qualified_prefix, default_scope, accumulator, mutated_ivars, # rubocop:disable Metrics/ParameterLists
                                    read_before_write = nil, init_writes = nil, method_assign_effects = nil,
                                    singleton_self: false)
          return if def_node.body.nil? || qualified_prefix.empty?
          # Issue #3155 — `def String.q` writes the ivars of another object.
          return if foreign_def?(def_node, qualified_prefix, false)

          class_name = qualified_prefix.join("::")
          singleton = singleton_self || def_node.receiver.is_a?(Prism::SelfNode) ||
                      ScopeIndexer.def_receiver_targets_lexical_self?(def_node.receiver, qualified_prefix)
          self_type =
            if singleton
              Type::Combinator.singleton_of(class_name)
            else
              Type::Combinator.nominal_of(class_name)
            end
          body_scope = CensusScope.census_body_scope(default_scope, qualified_prefix, self_type)

          # C2 — transient `@x = nil` dead-write elimination. When a method body opens with an unconditional `@x = nil`
          # (defensive init) and then *definitely* reassigns `@x` to a non-nil value on every completing path (a later
          # unconditional statement-level write, OR an `if/else` whose both branches write `@x`), the opening nil is
          # dead — it can never be observed at method exit. Recording it anyway folds a spurious `nil` constituent into
          # the flow-insensitive class-ivar union, which then poisons reads in OTHER methods (e.g. ipaddr `IN4MASK ^
          # @mask_addr` rejects the resulting `Integer | nil`). The set holds the `object_id`s of the transient write
          # nodes to skip; soundness is post-domination at the top statement level, so dropping the nil never hides a
          # real runtime-nil read.
          dead_writes = dead_transient_nil_writes(def_node.body, class_name, method_assign_effects)
          # #1154 — an `@x = x` from a declared parameter records the parameter's declared type.
          declared = DeclaredParamWrites::EMPTY
          declared = DeclaredParamWrites.collect(def_node, class_name, body_scope) unless singleton
          gather_ivar_writes(def_node.body, body_scope, class_name, accumulator,
                             EMPTY_GUARDED_IVARS, mutated_ivars, dead_writes, declared)
          if singleton
            singleton_written = (accumulator[SINGLETON_IVAR_WRITES] ||= {})[class_name] ||= Set.new
            define_method_written_ivars(def_node.body, singleton_written)
          end

          # B2.3 — collect per-method evidence for the read-before-write nil contribution. The accumulator-level
          # decision ("is this ivar truly read-before-write across the class lifetime?") is finalised at
          # `contribute_read_before_write_nil!` after the whole class body has been walked, using `init_writes` as the
          # soundness gate (an ivar written in `initialize` is initialised before any other method body runs).
          collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes, default_scope,
                                             singleton: singleton)
        end

        # ADR-38 block-form: collects ivar writes from a CallNode's block body (e.g. RSpec `before { @x = … }` /
        # `let(:x) { … }`) and folds them into `init_writes`, suppressing the read-before-write nil contribution the
        # same way a def-form initializer does. The block body is always treated as an initializer (the caller has
        # already verified the method name is declared as a block_method initializer), so there is no read-before-write
        # evidence collection step here.
        def collect_block_ivar_writes(block_node, qualified_prefix, default_scope, accumulator,
                                      mutated_ivars, init_writes)
          return if block_node.body.nil? || qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          self_type = Type::Combinator.nominal_of(class_name)
          body_scope = CensusScope.census_body_scope(default_scope, qualified_prefix, self_type)

          gather_ivar_writes(block_node.body, body_scope, class_name, accumulator,
                             EMPTY_GUARDED_IVARS, mutated_ivars)

          seen_writes = Set.new
          read_first = Set.new
          detect_read_before_write(block_node.body, seen_writes, read_first, class_name)
          init_set = (init_writes[class_name] ||= Set.new)
          seen_writes.each { |name| init_set << name }
        end

        # The ADR-38 initializer-call arm of {.walk_class_ivars}: a block-carrying call the
        # owner class declares as a block-form initializer contributes its `@x` writes to
        # `init_writes`. No-op everywhere else.
        def collect_initializer_block_ivars(node, owner, default_scope, accumulator,
                                            mutated_ivars, init_writes)
          return unless init_writes && !owner.empty? &&
                        node.block.is_a?(Prism::BlockNode) &&
                        block_initializer?(owner.join("::"), node.name, default_scope)

          collect_block_ivar_writes(node.block, owner, default_scope,
                                    accumulator, mutated_ivars, init_writes)
        end

        # The `attr_writer` family arm of {.walk_class_ivars} (#541). A writer declaration is the class's own
        # statement that `@x` takes values from outside, so it contributes what the hand-written untyped setter
        # `def x=(v) = @x = v` does: `Dynamic[top]`. Without it `@x = nil` in `initialize` was the only write
        # the seed saw, and `if @x` folded always-falsey on a field the class declares assignable. A setter
        # call site (`obj.x = v`) stays out, as ADR-58 WD2 settles; the declaration is class-level evidence
        # in the file the walk reads. `owner` is empty where no class owns an instance-side ivar (a
        # `class << self` body), and the macro contributes nothing there.
        def record_attr_writer_ivars(node, owner, accumulator)
          return if owner.empty?

          class_name = owner.join("::")
          ScopeIndexer.each_attr_macro_name(node) do |base|
            accumulate_ivar_type(accumulator, class_name, :"@#{base}", Type::Combinator.untyped)
          end
        end

        # The `define_method` arm of {.walk_class_ivars} (#1768). `define_method(:m) { … }` on the implicit
        # or `self` receiver installs its block as an instance method of `owner`, and Ruby runs the body on
        # the instance, so its `@x = …` writes are the instance's ivars exactly as a `def m` body's are —
        # `DefineMethodBlockSelf` narrows the block's `self` the same way when it is evaluated. Without this
        # arm an ivar `initialize` sets to `nil` and a `define_method` block sets to a String read as `nil`
        # in every sibling `def`. The block is typed under the instance `self`, as a def body is. Only the
        # literal-block form counts: a `define_method(:m, callable)` or `&callable` argument is not walked.
        # `owner` is empty in a `class << self` body (the call defines a class method there) and in an
        # anonymous factory body, and the block contributes nothing there. A `define_method` inside a `def`
        # body is already reached by that body's walk ({.gather_ivar_writes} enters blocks).
        #
        # An ADR-16 `block_as_methods:` call whose entry binds the receiver's instance (`get "/" do … end` in a
        # `Sinatra::Base` subclass under rigor-sinatra) takes the same arm: the plugin declares that its block runs as
        # an instance method of the receiver class, and `MacroBlockSelfType` narrows the block's `self` to that
        # instance.
        def collect_define_method_block_ivars(node, owner, default_scope, accumulator, mutated_ivars)
          return if owner.empty?

          class_name = owner.join("::")
          return unless method_body_block_call?(node, class_name, default_scope)

          block = node.block
          return unless block.body

          body_scope = CensusScope.census_body_scope(default_scope, owner, Type::Combinator.nominal_of(class_name))
          gather_ivar_writes(block.body, body_scope, class_name, accumulator, EMPTY_GUARDED_IVARS, mutated_ivars)
          written = (accumulator[DEFINE_METHOD_WRITES] ||= {})[class_name] ||= Set.new
          define_method_written_ivars(block.body, written)
        end

        # Issue #2488 — the explicit-receiver arm of {.walk_class_ivars}: `E.attr_writer :w` (or through `send`) records
        # `@w` as `Dynamic[top]` on `E`, as an `attr_writer` in `E`'s body does ({.record_attr_writer_ivars}), and an
        # `E.define_method(:m) { … }` block is walked as an instance body of `E`, as one in `E`'s body is
        # ({.collect_define_method_block_ivars}). `E` resolves as a `class_eval` receiver does; an unnameable one
        # contributes nothing. A call inside a `def` is that body's to walk.
        def collect_receiver_writer_ivars(node, owner, qualified_prefix, default_scope, accumulator, mutated_ivars)
          return if ReceiverWriterCall.receiver(node).nil?

          target = DeclarationWalk::Rules.eval_receiver_prefix(node, owner, qualified_prefix,
                                                               unnameable_self: owner.empty?)
          return if target.nil? || target.empty?

          class_name = target.join("::")
          ReceiverWriterCall.writer_ivars(node).each do |ivar|
            accumulate_ivar_type(accumulator, class_name, ivar, Type::Combinator.untyped)
          end
          body = ReceiverWriterCall.define_method_block(node)&.body
          return if body.nil?

          body_scope = CensusScope.census_body_scope(default_scope, target, Type::Combinator.nominal_of(class_name))
          gather_ivar_writes(body, body_scope, class_name, accumulator, EMPTY_GUARDED_IVARS, mutated_ivars)
          define_method_written_ivars(body, (accumulator[DEFINE_METHOD_WRITES] ||= {})[class_name] ||= Set.new)
        end

        # The ivars a `define_method` block body writes, in any write form, outside a nested `def` / `class` / `module`.
        def define_method_written_ivars(node, acc)
          return unless node.is_a?(Prism::Node)
          return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          case node
          when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
               Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode,
               Prism::InstanceVariableTargetNode
            acc << node.name
          end
          reflective = ReflectiveIvarWrite.literal_name(node)
          acc << reflective if reflective
          node.rigor_each_child { |child| define_method_written_ivars(child, acc) }
        end

        # ADR-38 block-form gate: true when a loaded plugin declares `method_name` a block-form initializer for
        # `class_name` (or an ancestor). Mirrors `additional_initializer?` but queries `covers_block_method?` instead of
        # `covers_method?`.
        def block_initializer?(class_name, method_name, default_scope)
          return false if class_name.nil? || default_scope.nil?

          environment = default_scope.environment
          registry = environment&.plugin_registry
          return false if registry.nil?
          return false if registry.respond_to?(:empty?) && registry.empty?
          return false unless registry.respond_to?(:additional_initializers)

          registry.additional_initializers.any? do |entry|
            entry.covers_block_method?(method_name) &&
              class_matches_constraint?(class_name, entry.receiver_constraint, environment)
          end
        rescue StandardError
          false
        end

        # Walks the method body in AST (== execution) order tracking ivar names whose first reference is a read. The set
        # is unioned into the class-wide `read_before_write` accumulator. For `initialize` def bodies, every write
        # target is unioned into `init_writes` instead — used by the finalisation step to suppress nil contribution for
        # ivars the constructor guarantees are initialised. A singleton-side def (`def self.initialize`) is no
        # initializer: `new` never calls it (#3419).
        def collect_read_before_write_evidence(def_node, class_name, read_before_write, init_writes,
                                               default_scope = nil, singleton: false)
          return if read_before_write.nil? || init_writes.nil?

          seen_writes = Set.new
          read_first = Set.new
          detect_read_before_write(def_node.body, seen_writes, read_first, class_name)

          # ADR-38 — `initialize` is the built-in initializer gate; a plugin may declare additional `def`-form
          # initializer methods (minitest `setup`, Rails `after_initialize`, DI setters) on a constrained class. Both
          # fold their writes into `init_writes`, suppressing the read-before-write nil contribution for sibling
          # readers.
          if !singleton && (def_node.name == :initialize ||
                            additional_initializer?(class_name, def_node.name, default_scope))
            init_set = (init_writes[class_name] ||= Set.new)
            seen_writes.each { |name| init_set << name }
            # #3419 — `initialize`'s own read of an ivar still unset is evidence too; a plugin's initializer may run
            # after code that sets it, so it gives none.
            read_first = EMPTY_GUARDED_IVARS
            read_first = initializer_own_nil_reads(def_node, class_name) if def_node.name == :initialize
          end

          return if read_first.empty?

          rbw_set = (read_before_write[class_name] ||= Set.new)
          read_first.each { |name| rbw_set << name }
        end

        # #3419 — the ivars `initialize` reads while they still hold `nil`: read before any write in the body, never
        # written later in it, and read in a top-level statement that comes before the first one that may run other
        # code of the object (a `super`, a `yield`, or a call on the implicit or `self` receiver other than
        # `raise`/`fail`), which may set the ivar first. Nothing else runs on the instance before `initialize`.
        def initializer_own_nil_reads(def_node, class_name)
          all_writes = Set.new
          detect_read_before_write(def_node.body, all_writes, Set.new, class_name)
          prefix_writes = Set.new
          read_first = Set.new
          top_level_statements(def_node.body).each do |stmt|
            break if runs_object_code?(stmt)

            detect_read_before_write(stmt, prefix_writes, read_first, class_name)
          end
          read_first - all_writes
        end

        # True when `node` holds a `super`, a `yield`, or a call on the implicit or `self` receiver other than
        # `raise`/`fail`, outside a nested def, class or lambda.
        def runs_object_code?(node)
          return false unless node.is_a?(Prism::Node)
          return false if OBJECT_CODE_BARRIERS.any? { |klass| node.is_a?(klass) }
          return true if node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode) ||
                         node.is_a?(Prism::YieldNode)
          return true if node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
                         !%i[raise fail].include?(node.name)

          node.compact_child_nodes.any? { |c| runs_object_code?(c) }
        end

        OBJECT_CODE_BARRIERS = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::LambdaNode].freeze
        private_constant :OBJECT_CODE_BARRIERS

        # ADR-38 — true when a loaded plugin declares `method_name` an additional initializer for `class_name` (or an
        # ancestor). Reads the plugin registry off the pre-pass scope's environment; the receiver-constraint match
        # reuses `Environment#class_ordering` (the same mechanism ADR-16 Tier A's `MacroBlockSelfType` uses). The whole
        # lookup is wrapped so any resolution failure degrades to "no match" — since the gate only ever SUPPRESSES a nil
        # contribution, a missed match is false-positive-safe (it merely leaves the existing nil widening in place).
        def additional_initializer?(class_name, method_name, default_scope)
          return false if class_name.nil? || default_scope.nil?

          environment = default_scope.environment
          registry = environment&.plugin_registry
          return false if registry.nil?
          return false if registry.respond_to?(:empty?) && registry.empty?
          return false unless registry.respond_to?(:additional_initializers)

          registry.additional_initializers.any? do |entry|
            entry.covers_method?(method_name) &&
              class_matches_constraint?(class_name, entry.receiver_constraint, environment)
          end
        rescue StandardError
          false
        end

        def class_matches_constraint?(class_name, constraint, environment)
          return true if class_name == constraint
          return false if environment.nil?

          ordering = environment.class_ordering(class_name, constraint)
          %i[equal subclass].include?(ordering)
        rescue StandardError
          false
        end

        IVAR_WRITE_NODES = [
          Prism::InstanceVariableWriteNode,
          Prism::InstanceVariableOrWriteNode,
          Prism::InstanceVariableAndWriteNode,
          Prism::InstanceVariableOperatorWriteNode
        ].freeze
        private_constant :IVAR_WRITE_NODES

        # Walks class-body level statements (i.e. NOT inside any nested DefNode / ClassNode / ModuleNode) and records
        # every `@x = …` write target as a class-body init. Consumed by `contribute_read_before_write_nil!` to exempt
        # ivars the author already knows might be nil (the `@x = nil` at class-body level is the canonical nullability
        # acknowledgement; the instance @x is technically a separate store, but the pragmatic intent is unambiguous).
        #
        # A literal `define_method` block is a method body, not class-body code (#1768): its writes reach the census as
        # a `def` body's do, so they must not exempt the ivar from the read-before-write `nil` either. Only its receiver
        # and arguments are walked.
        def collect_class_body_ivar_writes(node, class_name, init_writes)
          return unless node.is_a?(Prism::Node)
          return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          return collect_define_method_argument_writes(node, class_name, init_writes) if define_method_block_call?(node)

          if node.is_a?(Prism::InstanceVariableWriteNode) ||
             node.is_a?(Prism::InstanceVariableOrWriteNode) ||
             node.is_a?(Prism::InstanceVariableAndWriteNode) ||
             node.is_a?(Prism::InstanceVariableOperatorWriteNode)
            ((init_writes[CLASS_BODY_WRITES] ||= {})[class_name] ||= Set.new) << node.name
          end

          node.rigor_each_child do |child|
            collect_class_body_ivar_writes(child, class_name, init_writes)
          end
        end

        # The arguments of a `define_method` block call, walked by {.collect_class_body_ivar_writes} in place of the
        # call's children so the block body stays out of the class-body init writes.
        def collect_define_method_argument_writes(node, class_name, init_writes)
          node.arguments&.arguments&.each { |arg| collect_class_body_ivar_writes(arg, class_name, init_writes) }
        end

        # A `define_method` call with a literal block on the implicit or `self` receiver: the block is an instance
        # method body of the class the walk is in (#1768).
        def define_method_block_call?(node)
          DefineMethodBlockSelf.define_method_on_lexical_self?(node) && node.block.is_a?(Prism::BlockNode)
        end

        # A call with a literal block on the implicit or `self` receiver whose block is an instance method body of
        # `class_name`, the class the walk is in (#1768): `define_method`, or a call an ADR-16 `block_as_methods:` entry
        # declares runs its block as an instance method of the receiver class ({MacroBlockSelfType}). The entry is
        # matched on `Singleton[class_name]`, the receiver such a call has in the class body, through the same
        # receiver-ancestry match the evaluator narrows the block's `self` with, so the census counts exactly the blocks
        # whose `self` is narrowed to the instance.
        #
        # The class-body walk ({.collect_class_body_ivar_writes}) still records a `block_as_methods:` block's writes as
        # class-body writes, and {.exempt_class_body_writes!} takes back every ivar such a block writes.
        def method_body_block_call?(node, class_name, scope)
          return true if define_method_block_call?(node)
          return false unless node.block.is_a?(Prism::BlockNode)
          return false unless scope && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))

          MacroBlockSelfType.runs_as_receiver_instance_method?(
            scope: scope, call_node: node, receiver_type: Type::Combinator.singleton_of(class_name)
          )
        end

        def detect_read_before_write(node, seen_writes, read_first, class_name = nil)
          return unless node.is_a?(Prism::Node)
          return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          read_first << node.name if node.is_a?(Prism::InstanceVariableReadNode) && !seen_writes.include?(node.name)

          # N1 — parallel / multiple assignment (`@m, @n = [], []`). The ivar targets are `InstanceVariableTargetNode`s,
          # not `InstanceVariableWriteNode`s, so the generic descent below never records them as writes. Left unhandled,
          # an ivar written only via massign in `initialize` stays absent from `init_writes`, and
          # `contribute_read_before_write_nil!` then unions a spurious `nil` into its class-ivar seed — masking a
          # genuinely-typed `@m` (e.g. `Tuple[]`) as `T | nil` at every sibling read. The RHS runs before any
          # target is committed, so descend into `value` FIRST (an ivar read there is read-before-write), then mark
          # every ivar target as written.
          if node.is_a?(Prism::MultiWriteNode)
            detect_read_before_write(node.value, seen_writes, read_first, class_name) if node.value
            detect_multi_write_target_writes(node, seen_writes, read_first, class_name)
            return
          end

          # Descend BEFORE recording a write — `@x = @x + 1`'s RHS is an `InstanceVariableReadNode` that runs before the
          # write is committed; the read is therefore read-before-write semantically. `each_child` yields the value
          # child before the lvalue target (`compact_child_nodes` field order), matching this order.
          # #2490 — what a block whose `self` is another object reads or writes is that object's.
          each_census_child(node, class_name) do |c|
            detect_read_before_write(c, seen_writes, read_first, class_name)
          end

          seen_writes << node.name if IVAR_WRITE_NODES.any? { |klass| node.is_a?(klass) }
          # #1931 — a literal `instance_variable_set` is a write too; its value argument, read above, runs first.
          reflective = ReflectiveIvarWrite.literal_name(node)
          seen_writes << reflective if reflective
        end

        # Records each ivar target of a `MultiWriteNode` / nested `MultiTargetNode` into `seen_writes`, and descends
        # into any non-ivar target (a `CallTargetNode` / `IndexTargetNode` receiver such as `@obj.x, @y = …`) so an ivar
        # read inside a target receiver still counts as read-before-write.
        def detect_multi_write_target_writes(node, seen_writes, read_first, class_name = nil)
          targets = (node.lefts || []) + [node.rest].compact + (node.rights || [])
          targets.each do |target|
            case target
            when Prism::InstanceVariableTargetNode
              seen_writes << target.name
            when Prism::MultiTargetNode
              detect_multi_write_target_writes(target, seen_writes, read_first, class_name)
            when Prism::SplatNode
              inner = target.expression
              seen_writes << inner.name if inner.is_a?(Prism::InstanceVariableTargetNode)
            else
              detect_read_before_write(target, seen_writes, read_first, class_name)
            end
          end
        end

        IVAR_BARRIER_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ModuleNode].freeze

        # Issue #2490 — yields the children of `node` a census walk for `class_name` descends into: all of them, or only
        # those {CensusForeignBlock.census_children} keeps when `node` runs code whose `self` is another object. A nil
        # `class_name` keeps them all. A reentered `def` (#2941) is yielded as itself, so a walk that stops at a `def`
        # skips it; `def_bodies:` yields its body instead, for a walk that counts its writes. `reentry: false` (a
        # singleton-side `def`) keeps none of the reentered code.
        def each_census_child(node, class_name, def_bodies: false, reentry: true, &)
          outside = class_name && CensusForeignBlock.census_children(node, class_name, reentry: reentry)
          return node.rigor_each_child(&) unless outside

          outside.each do |child|
            child = child.body if def_bodies && child.is_a?(Prism::DefNode)
            yield child if child
          end
        end

        EMPTY_GUARDED_IVARS = Set.new.freeze

        # Shared empty result for a def that returns no ivar — the overwhelmingly common case.
        EMPTY_IVAR_SET = Set.new.freeze
        private_constant :EMPTY_IVAR_SET

        # Branch nesting a tail expression is followed through. Stopping early only UNDER-collects escapes.
        TAIL_VALUE_DEPTH_CAP = 8
        private_constant :TAIL_VALUE_DEPTH_CAP
        private_constant :EMPTY_GUARDED_IVARS

        def gather_ivar_writes(node, scope, class_name, accumulator, guarded_ivars = EMPTY_GUARDED_IVARS, # rubocop:disable Metrics/ParameterLists
                               mutated_ivars = nil, dead_writes = nil, declared = DeclaredParamWrites::EMPTY)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::InstanceVariableWriteNode)
            unless dead_writes&.include?(node.object_id)
              record_ivar_write(node, scope, class_name, accumulator,
                                guarded: guarded_ivars.include?(node.name), declared: declared[node])
            end
          else
            record_compound_ivar_write(node, scope, class_name, accumulator)
            record_reflective_ivar_write(node, scope, class_name, accumulator)
          end

          # N1 — parallel / multiple assignment (`old, @cb = @cb, block`, `@i, @o, @e, @thr = Open3.popen3(cmd)`). A
          # direct `InstanceVariableWriteNode` is the only write form this collector handled, so an ivar appearing as a
          # `MultiWriteNode` target was silently dropped from the class-ivar union — leaving it to seed as pure `nil`
          # (from a sibling `@cb = nil` ctor write, or absent entirely) and false-fire `if @cb` always-falsey /
          # `@thr.alive?` undefined-for-nil. Record each ivar target with its tuple-position RHS type where the RHS is
          # array/tuple-shaped, else the unanalyzable floor (the same `Dynamic[top]` a single write to an unknown RHS
          # records — an unanalyzable multi-write means unknown, not nil).
          record_multi_write_ivars(node, scope, class_name, accumulator)
          record_binding_target_ivars(node, scope, class_name, accumulator)

          record_ivar_mutator_call(node, class_name, mutated_ivars) if mutated_ivars

          # Don't recurse into nested defs, classes, or modules; their ivars belong to their own enclosing class.
          return if IVAR_BARRIER_NODES.any? { |klass| node.is_a?(klass) }

          if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars,
                                         mutated_ivars, dead_writes, declared)
            return
          end

          # #2490 — a block or `class <<` body whose `self` is another object writes that object's ivars. #2941 — a
          # `def` in it that runs on a `class_name` instance again counts its writes.
          # The reentry is for code that runs on an instance again, so a singleton-side `def` takes none.
          each_census_child(node, class_name, def_bodies: true, reentry: !scope.self_type.is_a?(Type::Singleton)) do |c|
            gather_ivar_writes(c, scope, class_name, accumulator, guarded_ivars, mutated_ivars, dead_writes, declared)
          end
        end

        # #1931 — `instance_variable_set` on `self` writes an ivar no write node shows ({ReflectiveIvarWrite}). A
        # literal name (`instance_variable_set(:@k, v)`) contributes the value's type to that ivar's entry, as `@k = v`
        # would. A name the analysis cannot read (`instance_variable_set(:"@#{k}", v)`, the options-hash constructor
        # idiom) may write any ivar of the class, so every entry of the class turns gradual once the walk ends
        # ({.make_reflective_classes_gradual!}): a reader in another method otherwise kept a write's literal
        # (`@timeout = 5` read as `5`) and reported a call on it.
        def record_reflective_ivar_write(node, scope, class_name, accumulator)
          return unless ReflectiveIvarWrite.self_write?(node)

          name = ReflectiveIvarWrite.literal_name(node)
          if name
            accumulate_ivar_type(accumulator, class_name, name, scope.type_of(ReflectiveIvarWrite.value_node(node)))
          else
            (accumulator[REFLECTIVE_OPAQUE_CLASSES] ||= Set.new) << class_name
          end
        end

        def make_reflective_classes_gradual!(accumulator, classes)
          classes&.each do |class_name|
            entries = accumulator[class_name]
            next if entries.nil?

            accumulator[class_name] = entries.transform_values { Type::Combinator.untyped }
          end
        end

        # Records `@ivar.<method>(...)` calls whose method is in `MutationWidening::SHAPE_MUTATORS` or
        # `SetMutation::MUTATORS` ({.ivar_census_mutator?}).
        # The class-ivar pre-pass uses the resulting set to widen the post-collected accumulator entries (see
        # {.widen_mutated_ivar_entries!}). Always-safe to over-collect: any name that the widening primitive declines is
        # ignored at finalization.
        def record_ivar_mutator_call(node, class_name, mutated_ivars)
          method_name, receiver = mutation_target(node)
          return if method_name.nil?
          return unless receiver.is_a?(Prism::InstanceVariableReadNode)
          return unless ivar_census_mutator?(method_name)

          per_class = (mutated_ivars[class_name] ||= {})
          per_ivar = (per_class[receiver.name] ||= Set.new)
          per_ivar << method_name
        end

        # The Set-only names (`add`, `merge`, … — issue #2294) are recorded here rather than in `SHAPE_MUTATORS`, which
        # every scan reads by name alone: there `merge` would make `Hash#merge`, which returns a new Hash, a mutation of
        # its receiver. The census is safe to over-collect, since {.widen_member_for_observed_mutators} reads each name
        # against the table of the carrier it widens.
        def ivar_census_mutator?(method_name)
          MutationWidening::SHAPE_MUTATORS.include?(method_name) || SetMutation::MUTATORS.include?(method_name)
        end

        # `[mutator name, receiver node]` for a node that mutates its receiver, `nil` otherwise.
        #
        # `@h[k] ||= v` and its `&&=` / `+=` siblings store through `[]=` but are not `[]=` CallNodes; missing them left
        # an `@h = {}` mutated only that way carrying its empty `HashShape` into every sibling method, so `@h.empty?`
        # folded to `Constant[true]` on a hash the class fills. A `Prism::IndexTargetNode` stores the same way wherever
        # it appears — a multi-assign `@h[k], x = …`, a `for @h[k] in` index, a `rescue => @h[k]` reference — and this
        # widening takes no stored value, so it counts in every position.
        # `IndexWriteWidening::CONTENT_WRITE_NODE_CLASSES` owns that list; it is spelled out here as an explicit
        # disjunction because that is what narrows `node` to something with a `#receiver` —
        # `CONTENT_WRITE_NODE_CLASSES.any? { … }` reads as a call on `Prism::Node` and Rigor rejects it, correctly.
        def mutation_target(node)
          return [node.name, node.receiver] if node.is_a?(Prism::CallNode)

          if node.is_a?(Prism::IndexOrWriteNode) || node.is_a?(Prism::IndexAndWriteNode) ||
             node.is_a?(Prism::IndexOperatorWriteNode) || node.is_a?(Prism::IndexTargetNode)
            return [IndexWriteWidening::MUTATOR, node.receiver]
          end

          nil
        end

        # Walk an `IfNode` / `UnlessNode` so writes inside the THEN body that look like defensive ivar initialisation
        # gain a `nil` union in the seeded type. Without this, `@x = v unless @x` records `Constant[v]` for `@x`, then
        # the predicate folds to that same constant and `flow.always-truthy-condition` fires against a working program.
        # Mirrors the falsey-literal skip `record_ivar_or_write` makes for `@x ||= <falsey>` — a `||=` whose rvalue
        # can only leave the ivar falsey contributes no useful precision either (#1175).
        #
        # Polarity-aware on purpose: only the THEN body picks up the guard. The ELSE branch of `if @x; ...; else; @x =
        # init; end` would otherwise be marked too — but that pattern (write @x in the else of `if @x`) is a separate
        # idiom whose surrounding reads of `@x` would then surface a nil-receiver FP. The ELSE branch is left ungarded
        # so those reads continue to type as they did before this fix.
        def walk_conditional_ivar_writes(node, scope, class_name, accumulator, guarded_ivars, # rubocop:disable Metrics/ParameterLists
                                         mutated_ivars = nil, dead_writes = nil, declared = DeclaredParamWrites::EMPTY)
          then_guards = then_body_guarded_ivars(node)
          then_guarded = then_guards.empty? ? guarded_ivars : (guarded_ivars | then_guards)

          gather_ivar_writes(node.predicate, scope, class_name, accumulator, guarded_ivars,
                             mutated_ivars, dead_writes, declared)
          if node.statements
            gather_ivar_writes(node.statements, scope, class_name, accumulator, then_guarded,
                               mutated_ivars, dead_writes, declared)
          end
          branch = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
          return unless branch

          gather_ivar_writes(branch, scope, class_name, accumulator, guarded_ivars,
                             mutated_ivars, dead_writes, declared)
        end

        # Returns the set of ivar names that, in the THEN body of this conditional, are statically known to be in a nil
        # / unset state — i.e. the body really IS the defensive-init half of the idiom. Conservative on purpose: only
        # the shapes that idiomatically express "the ivar is missing" qualify.
        #
        # For `unless P; body; end`, body runs when `P` is falsey:
        #   - `P = @x` (or `@x && other` / `@x || other`)            → @x is falsey
        #   - `P = defined?(@x)`                                     → @x is undefined
        #
        # For `if P; body; ...`, body runs when `P` is truthy:
        #   - `P = @x.nil?`                                          → @x is nil
        #   - `P = !@x` / `not @x`                                   → @x is falsey
        def then_body_guarded_ivars(node)
          names = Set.new
          if node.is_a?(Prism::UnlessNode)
            collect_truthy_test_ivars(node.predicate, names)
            collect_defined_test_ivars(node.predicate, names)
          else
            collect_nil_test_ivars(node.predicate, names)
          end
          names
        end

        def collect_truthy_test_ivars(node, names)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::InstanceVariableReadNode
            names << node.name
          when Prism::AndNode, Prism::OrNode
            collect_truthy_test_ivars(node.left, names)
            collect_truthy_test_ivars(node.right, names)
          end
        end

        def collect_defined_test_ivars(node, names)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::DefinedNode
            target = node.value
            names << target.name if target.is_a?(Prism::InstanceVariableReadNode)
          when Prism::AndNode, Prism::OrNode
            collect_defined_test_ivars(node.left, names)
            collect_defined_test_ivars(node.right, names)
          end
        end

        def collect_nil_test_ivars(node, names)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::CallNode
            receiver = node.receiver
            if receiver.is_a?(Prism::InstanceVariableReadNode) &&
               %i[nil? !].include?(node.name)
              names << receiver.name
            end
          when Prism::AndNode, Prism::OrNode
            collect_nil_test_ivars(node.left, names)
            collect_nil_test_ivars(node.right, names)
          end
        end

        # WD3 — ADR-41-style hard cap on how deep the same-class-call definite-assignment crediting recurses (the ctor
        # calls `mask!`, which could itself call another same-class helper). Cycle-guarded independently; the cap bounds
        # even acyclic chains.
        SAME_CLASS_CALL_DEPTH_CAP = 3
        private_constant :SAME_CLASS_CALL_DEPTH_CAP

        # WD3 — builds the per-class definite-assignment summary: per class, then per method, the ivars assigned non-nil
        # on every completing path. Used so a ctor's `dead_transient_nil_writes` can credit an indirect overwrite
        # through an unconditionally-called same-class method (ipaddr's `initialize` reassigns `@mask_addr` via
        # `mask!`).
        #
        # Each method's set is computed by the same suffix definite-assignment analysis used for the ctor seed, run from
        # the method body's first statement for every ivar the method writes anywhere. Same-class calls inside a method
        # are credited transitively (depth-capped, cycle-guarded) so the resulting FLAT table is correct at depth 0 for
        # the ctor lookup.
        def build_method_assign_effects(root)
          defs = collect_class_method_defs(root)
          effects = {}
          memo = {}.compare_by_identity
          defs.each do |class_name, methods|
            methods.each do |method_name, def_node|
              assigns = method_definite_assigns(class_name, method_name, def_node, defs, effects, memo, 0)
              (effects[class_name] ||= {})[method_name] = assigns unless assigns.empty?
            end
          end
          effects.freeze
        end

        # Collects `{class_name => {method_name => DefNode}}` for every instance-method def in the program. Singleton
        # defs (`def self.x`) are excluded — the ctor-call crediting only follows instance-method calls on `self`. Last
        # def wins on redefinition.
        # `def_owner` is the meta-new override described on {ScopeIndexer.walk_methods_and_def_nodes}: inside a
        # `K = Class.new { … }` block `self` is the class the write names, so `def` leaves record under
        # it while `Module.nesting` — and therefore `prefix` — stays lexical. `[]` marks the anonymous
        # block of an unnameable write; nil (the default) leaves defs under the lexical prefix.
        def collect_class_method_defs(root, prefix = [], acc = {}, def_owner: nil, singleton_cref: false,
                                      defs_singleton: false)
          return acc unless root.is_a?(Prism::Node)

          case root
          when Prism::ClassNode, Prism::ModuleNode
            return collect_decl_method_defs(root, prefix, acc, def_owner, singleton_cref)
          when Prism::SingletonClassNode
            # The expression evaluates in the enclosing cref; the body's cref is unnameable.
            return collect_singleton_method_defs(root, prefix, acc, def_owner, singleton_cref)
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantPathOrWriteNode
            return acc if collect_meta_new_method_defs?(root, prefix, acc, def_owner, singleton_cref)
          when Prism::DefNode
            # `defs_singleton` is the instance_eval split — `def` binds on the receiver's
            # singleton, an instance-def table this is not.
            return acc if defs_singleton

            record_collected_method_def(root, def_owner || prefix, acc)
            return acc
          when Prism::CallNode
            return acc if collect_call_method_defs?(root, prefix, acc, def_owner, singleton_cref,
                                                    defs_singleton)
          end

          root.rigor_each_child do |c|
            collect_class_method_defs(c, prefix, acc, def_owner: def_owner, singleton_cref: singleton_cref,
                                                      defs_singleton: defs_singleton)
          end
          acc
        end

        # The `def` leaf of {.collect_class_method_defs}: `def self.x` is a singleton def the
        # table does not collect; an ownerless prefix files nothing.
        def record_collected_method_def(root, rec_prefix, acc)
          (acc[rec_prefix.join("::")] ||= {})[root.name] = root unless rec_prefix.empty? || root.receiver
        end

        # The call arm of {.collect_class_method_defs}: dispatches to the anonymous meta-new and
        # eval-family handlers; any other call keeps walking its children below.
        def collect_call_method_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
          collect_anonymous_meta_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton) ||
            collect_eval_method_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
        end

        # The meta-new arm of {.collect_class_method_defs}: the write's receiver and arguments
        # evaluate in the enclosing context; the block's defs belong to the class the write
        # names, its declarations to the enclosing cref.
        def collect_meta_new_method_defs?(root, prefix, acc, enclosing_owner, singleton_cref)
          call = DeclarationWalk::Rules.meta_new_block_call(root)
          return false unless call

          child_prefix = DeclarationWalk::Rules.meta_new_child_prefix(root, prefix, enclosing_owner)
          meta_ownerless = singleton_cref &&
                           !DeclarationWalk::Rules.meta_new_path_target_nameable?(root, enclosing_owner)
          [call.receiver, *call.arguments&.arguments.to_a].compact.each do |part|
            collect_class_method_defs(part, prefix, acc, def_owner: enclosing_owner,
                                                         singleton_cref: singleton_cref)
          end
          if (body = DeclarationWalk::Rules.meta_new_block_body(root))
            collect_class_method_defs(body, prefix, acc,
                                      def_owner: (meta_ownerless ? nil : child_prefix) || [],
                                      singleton_cref: singleton_cref)
          end
          true
        end

        # The bare `Class.new { … }`-family call arm of {.collect_class_method_defs}: the
        # block's class has no name, so its `def`s belong to no nameable owner — they walk
        # under the empty prefix rather than the enclosing class.
        def collect_anonymous_meta_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
          return false unless DeclarationWalk::Rules.meta_new_constant_rvalue?(root) &&
                              root.block.is_a?(Prism::BlockNode)

          [root.receiver, *root.arguments&.arguments.to_a].compact.each do |part|
            collect_class_method_defs(part, prefix, acc, def_owner: def_owner,
                                                         singleton_cref: singleton_cref,
                                                         defs_singleton: defs_singleton)
          end
          if (body = root.block.body)
            collect_class_method_defs(body, prefix, acc, def_owner: [],
                                                         singleton_cref: singleton_cref)
          end
          true
        end

        # The eval-family arm of {.collect_class_method_defs}: the block's `def`s bind on the
        # receiver — a nameable receiver re-anchors the owner, a bare/`self` receiver keeps the
        # enclosing self, and a receiver that names nothing walks the body ownerless.
        def collect_eval_method_defs?(root, prefix, acc, def_owner, singleton_cref, defs_singleton)
          return false unless DeclarationWalk::Rules.receiver_eval_call?(root)

          [root.receiver, *root.arguments&.arguments.to_a].compact.each do |part|
            collect_class_method_defs(part, prefix, acc, def_owner: def_owner,
                                                         singleton_cref: singleton_cref,
                                                         defs_singleton: defs_singleton)
          end
          self_prefix = def_owner || prefix
          unnameable = DeclarationWalk::Rules.unnameable_eval_self?(false, def_owner, prefix, singleton_cref)
          eval_prefix = DeclarationWalk::Rules.eval_receiver_prefix(root, self_prefix, prefix,
                                                                    unnameable_self: unnameable) || []
          if (body = root.block.body)
            collect_class_method_defs(body, prefix, acc, def_owner: eval_prefix,
                                                         singleton_cref: singleton_cref,
                                                         defs_singleton: INSTANCE_EVAL_CALLS.include?(root.name))
          end
          true
        end

        # The class/module arm of {.collect_class_method_defs}: defs inside the body belong to
        # the declared class — `def_owner` clears — while an unnameable header below an
        # unnameable cref walks the body ownerless.
        def collect_decl_method_defs(root, prefix, acc, def_owner, singleton_cref)
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(root.constant_path, def_owner)
          child = self_decl || Source::ConstantPath.declaration_prefix(prefix, root.constant_path)
          if child && root.body
            # Under an unnameable cref a bare/`self::` header opens `#<singleton>::Name` —
            # ownerless; nameable headers re-anchor at a real cref.
            child_cref = DeclarationWalk::Rules.unnameable_decl?(root, self_decl, singleton_cref)
            collect_class_method_defs(root.body, child_cref ? [] : child, acc,
                                      singleton_cref: child_cref)
          end
          acc
        end

        def collect_singleton_method_defs(root, prefix, acc, def_owner, singleton_cref)
          collect_class_method_defs(root.expression, prefix, acc, def_owner: def_owner,
                                                                  singleton_cref: singleton_cref)
          if root.body
            # A `def` below `class <<` is a singleton method — this table collects
            # instance defs only, so the body walks ownerless.
            collect_class_method_defs(root.body, prefix, acc, def_owner: [],
                                                              singleton_cref: true)
          end
          acc
        end

        # Computes the definite-assignment set for one method, memoised per def node. The `memo` cycle-guards: a method
        # re-entered while its own summary is in progress contributes nothing (sound under-approximation), so mutual
        # recursion terminates.
        def method_definite_assigns(class_name, _method_name, def_node, defs, effects, memo, depth)
          return Set.new if def_node.body.nil?
          return memo[def_node] if memo.key?(def_node)
          return Set.new if depth >= SAME_CLASS_CALL_DEPTH_CAP

          memo[def_node] = Set.new # in-progress sentinel (cycle guard)
          statements = top_level_statements(def_node.body)
          candidates = ivar_write_targets(def_node.body)
          # A transient `@x = nil` opener whose own method reassigns it later must still count `@x` as assigned for
          # callers, so the crediting is computed at the BUILD-time depth.
          resolver = MethodEffectResolver.new(self, class_name, defs, effects, memo, depth)
          assigns = Set.new
          candidates.each do |ivar|
            if suffix_definitely_assigns_with_resolver?(statements, 0, ivar, class_name, resolver, depth)
              assigns << ivar
            end
          end
          memo[def_node] = assigns
        end

        # Every ivar this body assigns a non-nil value to ANYWHERE (the candidate set for the method's
        # definite-assignment scan).
        def ivar_write_targets(node, acc = Set.new)
          return acc unless node.is_a?(Prism::Node)

          acc << node.name if node.is_a?(Prism::InstanceVariableWriteNode) && !nil_literal_value?(node.value)
          node.rigor_each_child { |c| ivar_write_targets(c, acc) }
          acc
        end

        # Build-time variant of `suffix_definitely_assigns?` that resolves same-class calls through the lazy `resolver`
        # (which recurses into `method_definite_assigns` for not-yet-computed callees) rather than the finished flat
        # table.
        def suffix_definitely_assigns_with_resolver?(statements, from, target, class_name, resolver, depth)
          statements[from..].each do |stmt|
            outcome = statement_assignment_outcome(stmt, target, class_name, resolver, depth, nil)
            return true if outcome == :assigned
            return false if outcome == :terminates_unassigned
          end
          false
        end

        # Adapts `effects.dig(class, method)` for build-time crediting: when the callee summary is not yet in the flat
        # table, compute it on demand (depth+1) via `method_definite_assigns`.
        class MethodEffectResolver
          def initialize(indexer, class_name, defs, effects, memo, depth)
            @indexer = indexer
            @class_name = class_name
            @defs = defs
            @effects = effects
            @memo = memo
            @depth = depth
          end

          def dig(class_name, method_name)
            existing = @effects.dig(class_name, method_name)
            return existing if existing

            def_node = @defs.dig(class_name, method_name)
            return nil if def_node.nil?

            @indexer.send(:method_definite_assigns, class_name, method_name, def_node, @defs, @effects, @memo,
                          @depth + 1)
          end
        end

        # C2 — returns a Set of `object_id`s for transient `@x = nil` writes that a later statement in the same method
        # body *definitely* overwrites with a non-nil value on every completing path. Such a nil can never be the ivar's
        # value at method exit, so it must not contribute a `nil` constituent to the (flow-insensitive) class-ivar
        # union.
        #
        # Scope is deliberately narrow and post-domination-sound:
        #   - only the top-level statement sequence of the body is
        #     considered (no writes hidden inside loops / rescue / nested
        #     conditionals count as the "definite" overwrite, except the
        #     one structured `if/else` form below);
        #   - the killing statement is either an unconditional
        #     statement-level `@x = <non-nil>`, OR an `if/else` (with a
        #     real `else`) where BOTH branches' final top-level write to
        #     `@x` is non-nil. Both shapes overwrite `@x` on every path;
        #   - only `@x = nil` literal writes are ever marked dead — a
        #     non-nil transient is left untouched (it is already
        #     precision-additive in the union).
        def dead_transient_nil_writes(body, class_name = nil, method_assign_effects = nil)
          statements = top_level_statements(body)
          return nil if statements.length < 2

          dead = nil

          statements.each_with_index do |stmt, i|
            next unless stmt.is_a?(Prism::InstanceVariableWriteNode) && nil_literal_value?(stmt.value)

            # The opening `@x = nil` is dead when every completing path of the SUFFIX after it (normal end OR early
            # `return`, never a `raise`-terminated path) definitely reassigns `@x` non-nil. The suffix analysis credits
            # an unconditionally-called same-class method's own definite assignments via `method_assign_effects`.
            if suffix_definitely_assigns?(statements, i + 1, stmt.name, class_name, method_assign_effects)
              (dead ||= Set.new) << stmt.object_id
            end
          end

          dead
        end

        def top_level_statements(body)
          return [] if body.nil?
          return body.body if body.is_a?(Prism::StatementsNode)

          [body]
        end

        def nil_literal_value?(node)
          node.is_a?(Prism::NilNode)
        end

        # True when, starting from `statements[from]`, EVERY path that completes the method (falls off the end OR hits
        # an early `return`) definitely assigns `target` a non-nil value first. Paths terminated by `raise` are not
        # completing paths and are ignored (they never observe the ivar at method exit). A path that can fall through
        # `statements` without assigning fails.
        def suffix_definitely_assigns?(statements, from, target, class_name, effects)
          statements[from..].each do |stmt|
            outcome = statement_assignment_outcome(stmt, target, class_name, effects, 0, nil)
            # The statement assigned on every continuing path -> the suffix is satisfied no matter what follows.
            return true if outcome == :assigned
            # The statement terminates control here (return/raise) and the value it carried did not assign on every path
            # -> some completing path reached exit without the assignment.
            return false if outcome == :terminates_unassigned
            # Otherwise (:falls_through_unassigned) keep scanning the remaining statements.
          end
          # Fell off the end with no definite assignment.
          false
        end

        # Classifies a single statement's effect on `target`:
        #   :assigned                 — every path through the statement
        #                               that continues OR returns assigns
        #                               `target` non-nil (suffix is done);
        #   :terminates_unassigned    — the statement ends the method
        #                               (return/raise) on some path
        #                               without a definite assignment, so
        #                               a completing path escaped;
        #   :falls_through_unassigned — control may continue past it
        #                               without the assignment (keep
        #                               scanning the suffix).
        def statement_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
          case stmt
          when Prism::IfNode, Prism::UnlessNode
            conditional_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
          when Prism::CaseNode
            case_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
          when Prism::ReturnNode
            :terminates_unassigned
          else
            outcome = simple_statement_outcome(stmt, target, class_name, effects, depth, visiting)
            # #3419 — a statement that does not assign but holds a `return` anywhere (`c and return`, a loop's, a
            # block's, a `begin`'s) may leave the method there with `target` unassigned.
            outcome == :falls_through_unassigned && holds_return?(stmt) ? :terminates_unassigned : outcome
          end
        end

        # The outcome of a statement that is no conditional and no `return`: a write of `target` or an unconditional
        # same-class call that assigns it, and otherwise neutral — a bare `raise`/`fail` included, which terminates
        # without a completing path that observes the seed nil.
        def simple_statement_outcome(stmt, target, class_name, effects, depth, visiting)
          case stmt
          when Prism::InstanceVariableWriteNode
            stmt.name == target && !nil_literal_value?(stmt.value) ? :assigned : :falls_through_unassigned
          when Prism::CallNode
            if unconditional_call_assigns?(stmt, target, class_name, effects, depth, visiting)
              :assigned
            else
              :falls_through_unassigned
            end
          else
            :falls_through_unassigned
          end
        end

        # True when `node` holds a `return` that leaves the method: outside a nested def, class, module or lambda.
        def holds_return?(node)
          return false unless node.is_a?(Prism::Node)
          return true if node.is_a?(Prism::ReturnNode)
          return false if OBJECT_CODE_BARRIERS.any? { |klass| node.is_a?(klass) }

          node.compact_child_nodes.any? { |c| holds_return?(c) }
        end

        # True when a branch body (a StatementsNode / single node) definitely assigns `target` non-nil on every path
        # that completes the method through it, OR terminates every path by raise (vacuously safe — no completing path
        # observes the seed nil). Returns false if any path can complete/return without the assignment.
        # A branch body's (a StatementsNode / single node) outcome for `target`, read as a statement's is: `:assigned`
        # when it definitely assigns `target` non-nil on every path that completes the method through it, or ends every
        # path by raise (vacuously safe — no completing path observes the seed nil); `:terminates_unassigned` when a
        # path through it can return without the assignment; `:falls_through_unassigned` otherwise, an empty or absent
        # branch included.
        def branch_assignment_outcome(branch, target, class_name, effects, depth, visiting)
          stmts = top_level_statements(branch)
          return :falls_through_unassigned if stmts.empty?

          stmts.each do |stmt|
            outcome = statement_assignment_outcome(stmt, target, class_name, effects, depth, visiting)
            return outcome unless outcome == :falls_through_unassigned
          end
          # Reached the end of the branch without a definite assignment; safe only if the branch's last statement always
          # raises (no completing path falls out of it).
          always_raises?(stmts.last) ? :assigned : :falls_through_unassigned
        end

        # Joins the outcomes of the arms of a conditional or a `case`, a missing `else` arm falling through: `:assigned`
        # when every arm assigns, `:terminates_unassigned` when an arm may return without the assignment (#3419: `return
        # if c` is such an arm), and `:falls_through_unassigned` otherwise.
        def join_arm_outcomes(outcomes)
          return :assigned if outcomes.all?(:assigned)
          return :terminates_unassigned if outcomes.include?(:terminates_unassigned)

          :falls_through_unassigned
        end

        # `if`/`unless` is a definite assignment of `target` only when BOTH the then and else arms definitely assign (or
        # raise-out). A missing else arm means the fall-through path skips the assignment -> not definite. Modifier-form
        # `if`/`unless` (no else, single predicate'd statement) likewise. An `elsif` arm is read for a `return` alone:
        # it never counts as assigning.
        def conditional_assignment_outcome(node, target, class_name, effects, depth, visiting)
          else_branch = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
          then_outcome = branch_assignment_outcome(node.statements, target, class_name, effects, depth, visiting)
          else_outcome =
            case else_branch
            when Prism::ElseNode
              branch_assignment_outcome(else_branch.statements, target, class_name, effects, depth, visiting)
            when Prism::IfNode
              elsif_outcome = conditional_assignment_outcome(else_branch, target, class_name, effects, depth, visiting)
              elsif_outcome == :terminates_unassigned ? elsif_outcome : :falls_through_unassigned
            else
              :falls_through_unassigned
            end
          join_arm_outcomes([then_outcome, else_outcome])
        end

        # `case` is a definite assignment only when there is a real `else` clause AND every `when`/`in` body plus the
        # else body definitely assigns (or raises-out). A missing else lets an unmatched subject fall through
        # unassigned.
        def case_assignment_outcome(node, target, class_name, effects, depth, visiting)
          else_clause = node.else_clause
          branches = node.conditions.map { |c| c.respond_to?(:statements) ? c.statements : nil }
          branches << else_clause&.statements
          outcomes = branches.map do |b|
            branch_assignment_outcome(b, target, class_name, effects, depth, visiting)
          end
          join_arm_outcomes(outcomes)
        end

        # True when `node` (a single statement or its last statement) is an unconditional `raise`/`fail` call that
        # always terminates the path — used to treat raise-terminated branches as non-completing (they never observe the
        # seed nil).
        def always_raises?(node)
          node = top_level_statements(node).last if node.is_a?(Prism::StatementsNode)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.receiver.nil?

          %i[raise fail].include?(node.name)
        end

        # True when `call` is an unconditional, statement-level, implicit-self (or `self.`) call to a SAME-CLASS method
        # whose definite-assignment summary includes `target`. Calls through a block, on another receiver, or to an
        # unresolved name contribute nothing (the seed nil stays).
        def unconditional_call_assigns?(call, target, class_name, effects, depth, _visiting)
          return false if effects.nil? || class_name.nil?
          return false if depth >= SAME_CLASS_CALL_DEPTH_CAP
          return false unless call.is_a?(Prism::CallNode)
          return false unless call.block.nil?
          # Implicit self (`mask!(x)`) or explicit `self.mask!(x)` only.
          return false unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

          assigns = effects.dig(class_name, call.name)
          return false if assigns.nil?

          assigns.include?(target)
        end

        def record_ivar_write(node, scope, class_name, accumulator, guarded: false, declared: nil)
          rvalue_type = declared || accumulator[CONSTANT_IVAR_VALUES]&.type_of(node.value, scope) ||
                        scope.type_of(node.value)

          # `@x = nil unless @x` / `@y = false unless @y` — follow-up to the polarity-aware defensive-init guard fix
          # (defensive ivar-init with a nil / false rvalue). When the rvalue is itself a falsey
          # Constant, `union(rvalue, Constant[nil])` collapses (for `nil`) or doesn't widen the type's truthiness
          # profile (for `false`) — the predicate `unless @x` then folds to a single `Constant[nil]` / `Constant[false]`
          # and the `flow.always-truthy-condition` / `-always-falsey-` rule false-fires on the
          # no-op-but-documented-default idiom. Skip the seed contribution for this write — the sibling of
          # `record_ivar_or_write`'s no-truthy-rvalue skip for `@x ||= <falsey>` (#1175). Other writes to the same ivar
          # still contribute; the falsey-default write carries no useful precision the predicate hasn't already given
          # us. See tdiary-core HEAD `ee40c2b` `lib/tdiary/configuration.rb:157` for the worked site.
          return if guarded && falsey_constant?(rvalue_type)

          rvalue_type = EmptySeed.erase(node.value, rvalue_type)

          rvalue_type = Type::Combinator.union(rvalue_type, Type::Combinator.constant_of(nil)) if guarded
          accumulate_ivar_type(accumulator, class_name, node.name, rvalue_type)
        end

        # #1175 — compound writes. ADR-58 § WD5 deferred seeding `||=` with a reopen clause ("a corpus
        # surfaces a memo-read shape the `union(v, nil)` seed provably improves"); Rigor's own
        # `unit_scan.rb` is that shape: `@dispatch_top_level ||= true` went unrecorded, so the ivar
        # kept `Constant[false]` and `unless @dispatch_top_level` folded always-falsey.
        def record_compound_ivar_write(node, scope, class_name, accumulator)
          case node
          when Prism::InstanceVariableOrWriteNode
            record_ivar_or_write(node, scope, class_name, accumulator)
          when Prism::InstanceVariableAndWriteNode
            record_ivar_and_write(node, scope, class_name, accumulator)
          when Prism::InstanceVariableOperatorWriteNode
            record_ivar_operator_write(node, scope, class_name, accumulator)
          end
        end

        # `@x ||= v` — the memo idiom. The stored value is the old truthy value or `v`, so the rvalue
        # alone would be an honest contribution; the `nil` member stands in for the read-before-write
        # state — a `||=`-only ivar is `nil` until the first call runs the write. (That same union is
        # what the `guarded` flag adds to a plain write, and for the same reason: the flow-insensitive
        # seed has to know the predicate does not fold.) An rvalue with no truthy part is skipped outright
        # — `@x ||= false` can only leave `@x` falsey, the same "no useful precision" call the guarded
        # `@x = nil unless @x` skip makes, and `@x ||= raise "unset"` stores nothing at all. Seeded as
        # `nil`, the guard bound its own ivar, and `ExpressionTyper::Writes.compound_write_value` read
        # `truthy(nil) | bot` — an instance method that sig-gen declared `-> bot`.
        def record_ivar_or_write(node, scope, class_name, accumulator)
          rvalue_type = EmptySeed.erase(node.value, scope.type_of(node.value))
          return if Narrowing.narrow_truthy(rvalue_type).is_a?(Type::Bot)

          accumulate_ivar_type(accumulator, class_name, node.name,
                               Type::Combinator.union(rvalue_type, Type::Combinator.constant_of(nil)))
        end

        # `@x &&= v` writes only when `@x` already holds a truthy value — the ivar was made truthy by an
        # earlier write, so the rvalue is the contribution; no `nil` member (unlike `||=`, the write
        # cannot be the first thing to give the ivar a value, and a spurious nil here would fire
        # possible-nil at reads the pre-existing writes already typed).
        #
        # For the same reason the contribution counts only beside a write that can give the ivar a value,
        # so it waits under {AND_WRITE_CONTRIBUTIONS} until {.merge_held_ivar_writes!} sees the whole class:
        # that write may come later in source order. An ivar only `&&=` writes stays unseeded, the unbound
        # target `ExpressionTyper::Writes.compound_write_value` reads as `Dynamic[top]`. Seeded as the rvalue, the
        # `&&=` bound itself, and `if (@x &&= 1)` folded always-truthy on an ivar that is `nil` at runtime.
        def record_ivar_and_write(node, scope, class_name, accumulator)
          pending = (accumulator[AND_WRITE_CONTRIBUTIONS] ||= {})
          accumulate_ivar_type(pending, class_name, node.name, scope.type_of(node.value))
        end

        # `@x op= v` stores `@x op v`, so its contribution is the operator dispatched on what the class's
        # other writes store. Those writes sit in methods Ruby may call in any order, so the write waits
        # under {OPERATOR_WRITE_CONTRIBUTIONS} until {.merge_held_ivar_writes!} has them all. Dispatched on
        # the seed as the walk had it so far, a `+=` written above `@x &&= 1.5` never saw the `1.5`, `Float`
        # fell out of the seed, and `x == 2.5` folded always-falsey on a program that reaches it.
        def record_ivar_operator_write(node, scope, class_name, accumulator)
          pending = ((accumulator[OPERATOR_WRITE_CONTRIBUTIONS] ||= {})[class_name] ||= {})
          (pending[node.name] ||= []) << [node.binary_operator, scope.type_of(node.value), scope.environment]
        end

        # Folds the held `&&=` and `op=` writes into the seed once the walk has seen every write of the class.
        # An ivar only `op=` writes is seeded first, from the widened rvalues: the receiver would read as `nil`,
        # and `nil + v` raises at runtime, so the seed is unconstrained there and the rvalue is the right answer
        # for the dominant `+=` / `-=` / `|=` families. That seed counts as a write for the `&&=` merge, and the
        # `op=` results then join on top of the complete seed.
        def merge_held_ivar_writes!(accumulator)
          operator_writes = accumulator.delete(OPERATOR_WRITE_CONTRIBUTIONS) || {}
          seed_operator_only_ivars!(accumulator, operator_writes)
          merge_ivar_and_writes!(accumulator)
          merge_ivar_operator_writes!(accumulator, operator_writes)
        end

        def seed_operator_only_ivars!(accumulator, operator_writes)
          operator_writes.each do |class_name, ivars|
            ivars.each do |ivar_name, writes|
              next if accumulator.dig(class_name, ivar_name)

              rvalues = writes.map { |(_operator, rvalue_type, _environment)| rvalue_type }
              accumulate_ivar_type(accumulator, class_name, ivar_name,
                                   Type::Combinator.widen_value_pinned(Type::Combinator.union(*rvalues)))
            end
          end
        end

        # Folds the held `&&=` contributions into the seed of every ivar another write seeds, and drops the rest.
        def merge_ivar_and_writes!(accumulator)
          accumulator.delete(AND_WRITE_CONTRIBUTIONS)&.each do |class_name, ivars|
            seeded = accumulator[class_name]
            next if seeded.nil?

            ivars.each do |ivar_name, type|
              seeded[ivar_name] = Type::Combinator.union(seeded[ivar_name], type) if seeded.key?(ivar_name)
            end
          end
        end

        # The `op=` results join the complete seed. The methods run in any order, so a result is itself the
        # receiver of another held write: the dispatch repeats once per held write, which covers every chain one
        # call of each method can form, and stops early once a pass adds nothing. Not ADR-56's {BodyFixpoint}:
        # iterated to its fixed point, a lone counter's `@n += x` re-dispatched on its own `Dynamic[Integer | …]`
        # result and gained `Dynamic[top]`, and the widening pass that forces convergence dropped the `0` it
        # starts at — on nearly every counter ivar in the survey corpus. A chain that has to go on from a receiver
        # wider than {OPERATOR_CHAIN_UNION_CAP} floors to `Dynamic[top]` instead: each further pass dispatches
        # every held write on that union, and distinct tuple literals (`@a += [:s1]`, `@a += [:s2]`, …) grow it
        # by two members per write.
        def merge_ivar_operator_writes!(accumulator, operator_writes)
          operator_writes.each do |class_name, ivars|
            seeded = accumulator[class_name]
            ivars.each { |ivar_name, writes| seeded[ivar_name] = chain_operator_writes(seeded[ivar_name], writes) }
          end
        end

        def chain_operator_writes(seed, writes)
          writes.size.times do |pass|
            if pass.positive? && union_arity(Type::Combinator.widen_value_pinned(seed)) > OPERATOR_CHAIN_UNION_CAP
              return Type::Combinator.untyped
            end

            joined = Type::Combinator.union(seed, operator_write_results(seed, writes))
            break if joined == seed

            seed = joined
          end
          seed
        end

        def union_arity(type) = type.is_a?(Type::Union) ? type.members.size : 1

        # A cost guard local to this chain, not ADR-41's `union_size` budget, which stays unwired: it floors
        # silently, as {BodyFixpoint} does. Forty is the low end of the pathology band ADR-41's Slice 2a names for
        # such a valve; the widest `op=`-written ivar seed in the survey corpus has seven members.
        OPERATOR_CHAIN_UNION_CAP = 40
        private_constant :OPERATOR_CHAIN_UNION_CAP

        # The union of what each held `op=` write stores when `@x` holds `current`. The receiver is widened off
        # its value-pinned members first, or `Constant[0] + Constant[1]` would fold to a `Constant[1]` that pins
        # the ivar to one literal; the result is widened for the same reason.
        def operator_write_results(current, writes)
          receiver = Type::Combinator.widen_value_pinned(current)
          results = writes.map do |(operator, rvalue_type, environment)|
            dispatch = lambda do |type|
              MethodDispatcher.dispatch(receiver_type: type, method_name: operator, arg_types: [rvalue_type],
                                        environment: environment)
            end
            stored = dispatch.call(receiver) || partial_operator_result(receiver, rvalue_type, environment, dispatch)
            Type::Combinator.widen_value_pinned(stored)
          end
          Type::Combinator.union(*results)
        end

        # A union the dispatch declines as a whole because one member does (`nil + 1`, `:none + 1`, a `Dynamic`, a
        # class the pre-pass cannot resolve). The members it does type are dispatched together; a union with none
        # falls back to the rvalue. Declined whole, a `reset` storing `nil` beside `@x = 0.5` and `@x += 1` sent
        # the `+=` to its rvalue, `Float` left the seed, and `l > 1.0` under `l.is_a?(Float)` folded always-falsey.
        # The typed members are not dispatched one by one: a union of tuples dispatches to one `Array[…]`, member by
        # member to a tuple per chain.
        #
        # A declining member whose class the environment knows lacks the operator, so the write raises and stores
        # nothing; joined for it, the rvalue put an `Integer` no run can store beside `0.5 | Float | nil`, and a
        # sibling `def level = @x` declared `-> Float?` reported `def.return-type-mismatch`. Any other declining
        # member stores what the pre-pass cannot see, and keeps the rvalue it fell back to before. "Lacks" is
        # read from the RBS: a source monkey patch of a core operator, or an operator the RBS omits, reads as
        # raising, and so does an unwritten ivar's `nil`, which the seed does not model (`nil ^ true` is `true`).
        def partial_operator_result(receiver, rvalue_type, environment, dispatch)
          return rvalue_type unless receiver.is_a?(Type::Union)

          typed, declined = receiver.members.partition { |member| dispatch.call(member) }
          result = dispatch.call(Type::Combinator.union(*typed)) unless typed.empty?
          return rvalue_type if result.nil?
          return result if declined.all? { |member| lacks_operator?(member, environment) }

          Type::Combinator.union(result, rvalue_type)
        end

        def lacks_operator?(member, environment)
          member.is_a?(Type::Constant) || (member.is_a?(Type::Nominal) && environment.class_known?(member.class_name))
        end

        # The accumulator keys {.record_ivar_and_write} and {.record_ivar_operator_write} hold their writes under
        # until the walk ends. Every other key is a qualified class name, a String, so a Symbol can never collide
        # with one.
        AND_WRITE_CONTRIBUTIONS = :and_write_contributions
        OPERATOR_WRITE_CONTRIBUTIONS = :operator_write_contributions
        private_constant :AND_WRITE_CONTRIBUTIONS, :OPERATOR_WRITE_CONTRIBUTIONS

        # The same Symbol-key convention for two side tables the walk fills and {.build_class_ivar_index} removes
        # before anything reads class names: the ivars each class's `define_method` blocks write (in the
        # accumulator), and the class-body writes held out of `init_writes` until {.exempt_class_body_writes!}.
        DEFINE_METHOD_WRITES = :define_method_writes
        CLASS_BODY_WRITES = :class_body_writes
        # The classes a computed-name `instance_variable_set` may write any ivar of ({.record_reflective_ivar_write}).
        REFLECTIVE_OPAQUE_CLASSES = :reflective_opaque_classes
        # The census's {ConstantIvarValue}, which {.record_ivar_write} reads.
        CONSTANT_IVAR_VALUES = :constant_ivar_values
        # Issue #2931 — per class, the ivars a singleton-side `def` (`def self.x`) of it writes, which the census files
        # under the class too (#1958).
        SINGLETON_IVAR_WRITES = :singleton_ivar_writes
        private_constant :DEFINE_METHOD_WRITES, :CLASS_BODY_WRITES, :REFLECTIVE_OPAQUE_CLASSES, :CONSTANT_IVAR_VALUES,
                         :SINGLETON_IVAR_WRITES

        # Unions `type` into the class-ivar accumulator for `(class_name, ivar_name)`. Shared by the single-write and
        # multi-write (parallel-assignment) collectors.
        def accumulate_ivar_type(accumulator, class_name, ivar_name, type)
          accumulator[class_name] ||= {}
          existing = accumulator[class_name][ivar_name]
          accumulator[class_name][ivar_name] =
            existing ? Type::Combinator.union(existing, type) : type
        end

        # N1 — records each `InstanceVariableTargetNode` of a `MultiWriteNode` (parallel / multiple assignment) into the
        # class-ivar union. The per-slot type comes from `MultiTargetBinder`, the decomposition locals use (issue
        # #1110): a `Tuple` right-hand side element-wise, an `Array[T]` per slot, a union distributed over its members,
        # a value with no implicit `to_ary` as `[rhs]`, and anything else — an unanalyzable RHS such as
        # `Open3.popen3(cmd)` — as the `Dynamic[top]` floor (NOT `nil`: a multi-write we cannot decompose means the
        # value is *unknown*, mirroring what a single write to an unknown RHS records). Nested and splat targets
        # (`(@a, @b), *@c = …`) follow the same rules.
        #
        # The seed records the binder's default reading and drops its ADR-101 marks, exactly what a single
        # `@x = xs.first` write records: an `Array[T]` fixed slot seeds `T`, not `T | nil`. The table has no mark
        # channel, and a `T | nil` seed is not gated everywhere a declaration-sourced nil is — a sibling returning the
        # ivar against a declared `-> T` would fire `def.return-type-mismatch` on a correct program (ADR-5).
        #
        # The ADR-57 slot softening is the opposite case and is turned off (`soften_slots: false`): dropping the `nil`
        # of a present `X | nil` tuple slot, or a union member's bare `nil`, is honest for a local only because the
        # binder marks the name, and the seed drops the mark. Without it a sibling's `if @b` / `raise unless @b` would
        # fold on a `nil` that is reachable, so the seed keeps the genuine `X | nil` the pre-#1110 indexer kept.
        def record_multi_write_ivars(node, scope, class_name, accumulator)
          return unless node.is_a?(Prism::MultiWriteNode)

          rhs_type = scope.type_of(node.value)
          ivars = MultiTargetBinder.bind_marked(node, rhs_type, scope: scope, soften_slots: false).ivars
          # #2499 — `@a, @b = {}, []` erases each empty seed as a single write does.
          values = EmptySeed.multi_write_values(node)
          ivars.each do |name, type|
            accumulate_ivar_type(accumulator, class_name, name, EmptySeed.erase(values[name], type))
          end
        end

        # Issue #1217 — `rescue => @err` and `for @x in xs` (with `for *@x in`, `for @x, y in`) write the ivar through a
        # target node, not an `InstanceVariableWriteNode`, so the census missed them: a sibling method read the
        # constructor's `@err = nil` alone and folded `if @err` always-falsey. A rescue reference contributes the
        # exception instance type the clause names; a `for` index the `Dynamic[top]` floor, since the census does not
        # type the element, and an unknown value is honest where a missing one is not.
        def record_binding_target_ivars(node, scope, class_name, accumulator)
          names = BindingTargets.names(node, Prism::InstanceVariableTargetNode)
          return if names.empty?

          type = BindingTargets.value_type(node, scope)
          names.each { |name| accumulate_ivar_type(accumulator, class_name, name, type) }
        end

        # The names a `rescue =>` reference or a `for` index binds through a target of `target_class`, looking through
        # a splat and a multi-target index.
        module BindingTargets
          EMPTY = [].freeze
          private_constant :EMPTY

          module_function

          def names(node, target_class)
            root =
              case node
              when Prism::RescueNode then node.reference
              when Prism::ForNode then node.index
              end
            return EMPTY if root.nil?

            collect(root, target_class, [])
          end

          # What an ivar target is written with: a rescue reference's exception instance, as the in-method binding
          # types it ({ErrorInfo.rescue_exception_type}), a `for` index's `Dynamic[top]` floor.
          def value_type(node, scope)
            return Type::Combinator.untyped unless node.is_a?(Prism::RescueNode)

            ErrorInfo.rescue_exception_type(node) { |exception_node| scope.type_of(exception_node) }
          end

          def collect(target, target_class, acc)
            case target
            when target_class then acc << target.name
            when Prism::SplatNode then collect(target.expression, target_class, acc) if target.expression
            when Prism::MultiTargetNode
              [*target.lefts, target.rest, *target.rights].compact.each { |t| collect(t, target_class, acc) }
            end
            acc
          end
        end

        def falsey_constant?(type)
          type.is_a?(Type::Constant) && (type.value.nil? || type.value == false)
        end

        def foreign_def?(def_node, qualified_prefix, in_singleton_class)
          ScopeIndexer.def_side(def_node, qualified_prefix, in_singleton_class).nil?
        end

        # The subset of `ScopeIndexer::ATTR_MACROS` that defines a writer, which the class-ivar pass counts as a write
        # ({.record_attr_writer_ivars}).
        ATTR_WRITER_MACROS = %i[attr_writer attr_accessor].freeze

        private_class_method :instance_side_writes, :exempt_class_body_writes!, :contribute_read_before_write_nil!,
                             :record_aliased_ivar_mutations!, :returned_ivars_by_method, :returned_ivars,
                             :collect_explicit_return_ivars, :tail_value_nodes, :tail_value_children,
                             :gather_aliased_mutations, :escaped_ivars_for_receiver, :widen_mutated_ivar_entries!,
                             :widen_type_for_observed_mutators, :widen_member_for_observed_mutators,
                             :widen_constant_for_observed_mutators, :widen_member_for_lookup_mutators,
                             :walk_class_ivars, :walk_ivars_leaf?, :walk_ivars_meta_new?, :walk_ivars_meta_call?,
                             :walk_ivars_eval_call?, :walk_singleton_class_ivars, :walk_ivars_declaration,
                             :collect_def_ivar_writes, :collect_block_ivar_writes, :collect_initializer_block_ivars,
                             :record_attr_writer_ivars, :collect_define_method_block_ivars,
                             :collect_receiver_writer_ivars, :define_method_written_ivars, :block_initializer?,
                             :collect_read_before_write_evidence, :initializer_own_nil_reads, :runs_object_code?,
                             :additional_initializer?,
                             :class_matches_constraint?, :collect_class_body_ivar_writes,
                             :collect_define_method_argument_writes, :define_method_block_call?,
                             :method_body_block_call?, :detect_read_before_write, :detect_multi_write_target_writes,
                             :each_census_child, :gather_ivar_writes, :record_reflective_ivar_write,
                             :make_reflective_classes_gradual!, :record_ivar_mutator_call, :ivar_census_mutator?,
                             :mutation_target, :walk_conditional_ivar_writes, :then_body_guarded_ivars,
                             :collect_truthy_test_ivars, :collect_defined_test_ivars, :collect_nil_test_ivars,
                             :build_method_assign_effects, :collect_class_method_defs, :record_collected_method_def,
                             :collect_call_method_defs?, :collect_meta_new_method_defs?,
                             :collect_anonymous_meta_defs?, :collect_eval_method_defs?, :collect_decl_method_defs,
                             :collect_singleton_method_defs, :method_definite_assigns, :ivar_write_targets,
                             :suffix_definitely_assigns_with_resolver?, :dead_transient_nil_writes,
                             :top_level_statements, :nil_literal_value?, :suffix_definitely_assigns?,
                             :statement_assignment_outcome, :simple_statement_outcome, :holds_return?,
                             :branch_assignment_outcome, :join_arm_outcomes,
                             :conditional_assignment_outcome, :case_assignment_outcome, :always_raises?,
                             :unconditional_call_assigns?, :record_ivar_write, :record_compound_ivar_write,
                             :record_ivar_or_write, :record_ivar_and_write, :record_ivar_operator_write,
                             :merge_held_ivar_writes!, :seed_operator_only_ivars!, :merge_ivar_and_writes!,
                             :merge_ivar_operator_writes!, :chain_operator_writes, :union_arity,
                             :operator_write_results, :partial_operator_result, :lacks_operator?,
                             :accumulate_ivar_type, :record_multi_write_ivars, :record_binding_target_ivars,
                             :falsey_constant?, :foreign_def?
      end
    end
  end
end
