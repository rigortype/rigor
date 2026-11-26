# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../../analysis/dependency_recorder"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../declaration_walk/rules"
require_relative "../global_write_census"
require_relative "../receiver_writer_call"
require_relative "census_scope"
require_relative "empty_seed"

module Rigor
  module Inference
    module ScopeIndexer
      # The constant tables of one file, moved out of `scope_indexer.rb` whole (ADR-116 WD9, #3400). They are two
      # walks over every constant write and the rules both ask: the typed in-source table (slice 7 phase 9), which
      # types each rvalue; the publication census (#644), which is syntactic and files a descriptor per name; and
      # the write-target rules, which say what `self` a block runs under and which name a write targets.
      #
      # Four functions are public, because another file calls each. {.build_in_source_constants} is the typed
      # walk's entry, which `ScopeIndexer.index`, {PreEvalConstants} and {ConstantIvarValue} call.
      # {.constant_write_census} is the census's: `ScopeIndexer.seed_constant_tables` and the cross-file fold
      # (`ScopeIndexer.merge_constant_literal_tables`) read the tables it answers. {.rebound_block_self} is the
      # one rule other walks ask: the mixin tables (`MixinTables.walk_mixin_call_children`) and
      # {SharedWalkTables}. {.dynamic_target_key} spells the wildcard key of a write through a base nothing names,
      # which the fold files too (`ScopeIndexer.apply_dynamic_target_writes`). The other 36 are private: the two
      # walks with their arms and recording steps, the rest of the rules, and {.constant_writes_for_file}, which
      # no file of `lib/` calls and the specs reach through `send`.
      #
      # It asks {DeclarationWalk::Rules} for each declaration context and {CensusScope} for two things, at one site
      # each: {CensusScope.census_body_scope} (the scope a census types a body's rvalues under, which the ivar and
      # the class-variable censuses ask too) and {CensusScope.census_nesting} (the chain that scope answers
      # `Module.nesting` with). It calls nothing left in `scope_indexer.rb`. Four constants moved with it, the ones
      # only it read: {CONSTANT_UNPUBLISHABLE} (public, as it was), `OPAQUE_SELF_BLOCK_CALLS`, `OBJECT_OWNER` and
      # `CensusTables`. It reads `ScopeIndexer::OPAQUE_SELF`, `RECEIVER_EVAL_CALLS`, `CONSTANT_MEMO` and
      # `DYNAMIC_TARGET_PREFIX` lexically, as {NodePropagation} reads the indexer's constants: other rows of
      # `scope_indexer.rb` or other files read each.
      #
      # `scope_indexer.rb` requires this file, and this file does not require it back. It requires the file of
      # what else it names, with one exception: `in_effect_refinements.rb` reads `Scope::DiscoveryIndex` as it
      # loads and does not require `scope.rb`, so a require of it here would stop this file, and
      # {SharedWalkTables}, which requires this one, from loading alone. `scope_indexer.rb` has loaded both by the
      # time it requires this file. So the file loads alone, and until `scope_indexer.rb` has loaded little of it
      # answers: {.constant_write_census} and {.dynamic_target_key} are a `NameError`, {.rebound_block_self}
      # answers only for a node that is no block-taking call, and {.build_in_source_constants} only for a program
      # with no `class` or `module` header and no call that takes a block.
      module ConstantTables # rubocop:disable Metrics/ModuleLength
        module_function

        # Issue #644 — the census descriptor for a constant write that publishes no value: an unfoldable or
        # non-literal rvalue, an operator / multi-assign / dynamic-path form, or a name this file writes twice.
        # A Symbol, so it is distinguishable from a `[literal]` descriptor by class alone and rides the ADR-85
        # seed bundle through `Marshal` unchanged.
        CONSTANT_UNPUBLISHABLE = :unpublishable

        # Slice 7 phase 9 — in-source constant value pre-pass. Walks the entire program (top-level AND inside class /
        # module / def bodies) for `Prism::ConstantWriteNode` and `Prism::ConstantPathWriteNode`, types each rvalue, and
        # accumulates by qualified name. Constants defined inside a class body are qualified with the surrounding class
        # path; a constant written via a path resolves its own namespace through the enclosing nesting first
        # ({.constant_path_write_key}) — which is where this walk and the
        # [#644](https://github.com/rigortype/rigor/issues/644) publication census below stopped agreeing about
        # a path write's name.
        def build_in_source_constants(root, default_scope)
          accumulator = {}
          walk_constant_writes(root, [], default_scope, accumulator)
          accumulator.freeze
        end

        # The block-taking call whose block `self` this walk cannot name even when the receiver names a
        # class: a `define_method` body runs on the receiver's INSTANCE at call time, an object
        # nothing in the source names, so a `self::` write inside it is declined — gradual for
        # the case where the instance is a class or module, and no guess for the rest.
        OPAQUE_SELF_BLOCK_CALLS = %i[define_method].freeze
        private_constant :OPAQUE_SELF_BLOCK_CALLS

        # {DeclarationWalk::Rules::OBJECT_OWNER}, bound here: the owner whose constants the census spells BARE.
        OBJECT_OWNER = DeclarationWalk::Rules::OBJECT_OWNER
        private_constant :OBJECT_OWNER

        def walk_constant_writes(node, qualified_prefix, default_scope, accumulator, self_owner = nil,
                                 singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::SingletonClassNode
            return walk_singleton_class_writes(node, qualified_prefix, default_scope, accumulator,
                                               self_owner, singleton_cref)
          when Prism::ClassNode, Prism::ModuleNode
            return if walk_typed_declaration?(node, qualified_prefix, default_scope, accumulator,
                                              self_owner, singleton_cref)
          when Prism::ConstantWriteNode
            # A bare write under an unnameable cref — anywhere lexically below `class <<`,
            # including inside an eval or `Class.new` block, since `Module.nesting` never
            # rebinds — lands on that cref's constant table, a name nothing else can
            # produce, so it declines rather than filing under the enclosing class.
            unless singleton_cref
              record_constant_write(node, qualified_prefix, default_scope, accumulator,
                                    qualified_write_name(qualified_prefix, node.name.to_s), self_owner)
            end
            return
          when Prism::ConstantPathWriteNode
            full = constant_path_write_key(node.target, qualified_prefix, default_scope, self_owner)
            record_constant_write(node, qualified_prefix, default_scope, accumulator, full, self_owner) if full
            return
          end

          walk_constant_write_children(node, qualified_prefix, default_scope, accumulator, self_owner,
                                       singleton_cref)
        end

        # `self` inside a `class <<` body is the singleton: `self`-anchored and bare write
        # targets land on its constant table (unnameable, so both decline), and the body is
        # entered with an OPAQUE self so a `self::`-anchored eval receiver declines — the
        # read raises NameError at runtime unless the constant lives on that singleton.
        def walk_singleton_class_writes(node, qualified_prefix, default_scope, accumulator,
                                        self_owner, singleton_cref)
          walk_constant_writes(node.expression, qualified_prefix, default_scope, accumulator,
                               self_owner, singleton_cref: singleton_cref)
          return unless node.body

          walk_constant_writes(node.body, qualified_prefix, default_scope, accumulator,
                               OPAQUE_SELF, singleton_cref: true)
        end

        # The class/module arm of {.walk_constant_writes}. Under an unnameable cref a
        # bare/`self::` declaration pushes `#<singleton>::Name` — still unnameable — so the body
        # keeps the OPAQUE self, the cref flag, and the ENCLOSING prefix: `child_prefix`'s
        # `C::D` would seed `C::D::Foo` write candidates no program can produce, and the only
        # nameable rungs below are the enclosing ones. A nameable header re-anchors at a
        # nameable cref. Returns whether the declaration's body was walked.
        def walk_typed_declaration?(node, qualified_prefix, default_scope, accumulator, self_owner,
                                    singleton_cref)
          self_base = rebound_self_base(self_owner)
          self_base = [] if self_base == OPAQUE_SELF
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, self_base)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return false unless child_prefix && node.body

          child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
          child_scope = if child_cref
                          default_scope
                        else
                          DeclarationWalk::Rules.scope_entering_declaration(default_scope, node.constant_path)
                        end
          walk_constant_writes(node.body, child_cref ? qualified_prefix : child_prefix, child_scope,
                               accumulator, child_cref ? OPAQUE_SELF : nil, singleton_cref: child_cref)
          true
        end

        # The self a `self::`-anchored eval receiver resolves against, given the enclosing
        # body's self — an eval block's own receiver. A String owner splits into its constant
        # segments; an OPAQUE or nil self passes through unchanged — an OPAQUE self stays
        # opaque either way.
        def rebound_self_base(owner)
          owner.is_a?(String) ? owner.split("::") : owner
        end

        # Recursion into `node`'s children, swapping `self` for the ONE child a self-rebinding call evaluates
        # under a different receiver — its block. Every other child, and every child of a node that rebinds
        # nothing, keeps the `self` it was reached under.
        #
        # The block is identified by its CLASS rather than by identity against `CallNode#block`. These walks
        # recurse over every node kind, so `node` here is the whole `Prism::Node` union and reading a member
        # only a call carries off it is exactly the shape Rigor's own check rejects. The test is equivalent:
        # `rebound` is non-nil only where {.rebound_block_self} already saw a `Prism::BlockNode` in the `block`
        # field, and no other child of a call can be one — a receiver is an expression, arguments sit under
        # `ArgumentsNode`, and a `&blk` pass-through is a `BlockArgumentNode`.
        def walk_constant_write_children(node, qualified_prefix, default_scope, accumulator, self_owner,
                                         singleton_cref)
          rebound = rebound_block_self(node, qualified_prefix, default_scope, nil, self_owner)
          node.rigor_each_child do |child|
            rebinds_self = rebound && child.is_a?(Prism::BlockNode)
            owner = rebinds_self ? rebound : self_owner
            # A self-rebinding block moves `self` but not `Module.nesting` — the cref flag
            # passes through unchanged, so a bare write inside `Foo.class_eval { … }`
            # under `class <<` still lands on the singleton's table and declines.
            walk_constant_writes(child, qualified_prefix, default_scope, accumulator, owner,
                                 singleton_cref: singleton_cref)
          end
        end

        # Issue #705 — the class or module `self` names inside `node`'s BLOCK, or nil when `node` opens no
        # block that rebinds `self` (an ordinary block keeps the `self` it closed over, so a `self::BAR = …`
        # there is still the enclosing declaration's and every walk below this stays as it was).
        #
        # {OPAQUE_SELF} where the new `self` reaches no class or module name: a `class_eval` receiver that is
        # not a static constant path, an {OPAQUE_SELF_BLOCK_CALLS} body, and a `Class.new { … }` /
        # `Module.new` / `Struct.new` / `Data.define` block no enclosing constant write names. Declining there
        # costs a resolution the engine never had; naming the LEXICAL enclosure instead is the guess that fires,
        # because it is the one name Ruby is guaranteed NOT to have written.
        #
        # `meta_owner` is the name such a write DOES give the block's class, threaded one hop down by the
        # caller ({.meta_new_block_owner}) ([#710](https://github.com/rigortype/rigor/issues/710)). It is
        # supplied only by the publication census; the typed walk returns at a `ConstantWriteNode` without
        # descending into its rvalue, so no `self::` write inside one reaches that walk at all.
        #
        # `self_owner` is the enclosing body's self as the walk carries it, unsplit. Every walk asks this at
        # every node it visits, and only an eval call reads the self, so the split waits until one does
        # ([#1502](https://github.com/rigortype/rigor/issues/1502)).
        def rebound_block_self(node, qualified_prefix, default_scope = nil, meta_owner = nil,
                               self_owner = nil)
          return nil unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)
          return OPAQUE_SELF if OPAQUE_SELF_BLOCK_CALLS.include?(node.name)
          return meta_owner || OPAQUE_SELF if DeclarationWalk::Rules.meta_new_constant_rvalue?(node)
          return nil unless RECEIVER_EVAL_CALLS.include?(node.name)

          eval_receiver_self(node.receiver, qualified_prefix, default_scope, rebound_self_base(self_owner))
        end

        # Issue #710 — the qualified name a `Klass = Class.new { … }` gives the block's class, or nil when
        # `node` is not that form. Ruby names the constructed class after the constant it is first assigned to,
        # so `self::X = 7` in the block writes `Klass::X` and nothing about it is opaque. The recognition is
        # {DeclarationWalk::Rules.meta_new_block_body}'s, shared with the block-as-method walk.
        #
        # A constant PATH write (`N::Made = Class.new { … }`) keeps the opaque answer even though that recognition
        # now takes it ([#703](https://github.com/rigortype/rigor/issues/703)). This census keys a path write AS
        # WRITTEN ({.constant_path_write_name}) rather than through the nesting, so naming the block's class here
        # would publish a `self::X = …` inside it under a name Ruby does not give it; declining suppresses the
        # name instead, which is the gradual direction. Moving it belongs with moving the census's own path key.
        #
        # Issue #963 — the `||=` spellings keep the opaque answer for the same reason the path spelling does. This
        # census records every or-write UNPUBLISHABLE (the constant may already hold something else), so naming the
        # block's class here would publish `Const::X` under a name the census has just declined to publish itself.
        # The `.freeze` spelling is a plain `ConstantWriteNode` and is taken; its tail is threaded through by
        # {.walk_constant_write_census}.
        def meta_new_block_owner(node, qualified_prefix)
          return nil unless node.is_a?(Prism::ConstantWriteNode) && DeclarationWalk::Rules.meta_new_block_body(node)

          qualified_write_name(qualified_prefix, node.name.to_s)
        end

        # The `self` a `Recv.class_eval { … }` block runs under. An implicit or literal `self` receiver leaves
        # `self` where it was — nil, so nothing about the walk changes. A static constant path resolves the way
        # a path write's own namespace resolves ({.resolved_write_namespace}); anything else is opaque. A nil
        # `default_scope` is the publication census, which has no class knowledge to resolve through and keys a
        # path AS WRITTEN, so the receiver keeps its spelling there too.
        def eval_receiver_self(receiver, qualified_prefix, default_scope, self_prefix = nil)
          return nil if receiver.nil? || receiver.is_a?(Prism::SelfNode)

          # `self::X` anchors to the enclosing self — `self_prefix` carries the eval-derived
          # owner inside an eval body, so `Y.class_eval { self::X.class_eval { include T } }`
          # still resolves `Y::X`; outside one it is the lexical prefix either way. An
          # unnameable enclosing self keeps the answer opaque.
          if (tail = DeclarationWalk::Rules.self_anchored_tail(receiver))
            return OPAQUE_SELF if self_prefix == OPAQUE_SELF

            prefix = self_prefix || qualified_prefix
            return DeclarationWalk::Rules.collapse_object_owner(prefix + tail).join("::")
          end

          name = Source::ConstantPath.qualified_name_or_nil(receiver)
          return OPAQUE_SELF if name.nil?
          return name if default_scope.nil? || qualified_prefix.empty? || Source::ConstantPath.rooted?(receiver)

          resolved_write_namespace(name, qualified_prefix, default_scope)
        end

        # Issue #690 — `enclosing_prefix` is the lexical declaration prefix the write SITS UNDER, `full` the
        # qualified name it WRITES. The two coincide for a bare `BAR = …` and diverge for a `Foo::BAR = …`,
        # which is why they are separate parameters. One parameter served both roles, so the path form had to
        # pass it EMPTY to keep the caller-supplied name intact — and that lost the key's qualification and the
        # rvalue's lexical context together, in the same argument.
        #
        # Issue #705 — and the rvalue needs BOTH halves of the context separately as well, because a
        # `class_eval` block moves one and not the other. `Module.nesting` stays lexical, so a bare `Post` in
        # `Other.class_eval { … }` inside `module Admin` is still `Admin::Post`; `self` becomes the RECEIVER, so
        # `self` and an implicit-self call in the same block answer on `Other`. Reading the self type off
        # `enclosing_prefix` typed `self::REF = self` as `singleton(Admin)` and `self::V = build` through
        # `Admin.build` — wrong on correct code, and reachable at a reader the moment the key stopped being a
        # guess. `self_owner` is a String exactly when the walk resolved a rebound `self`.
        def record_constant_write(node, enclosing_prefix, default_scope, accumulator, full, self_owner = nil)
          owner = self_owner.is_a?(String) ? self_owner : enclosing_prefix.join("::")
          body_scope = default_scope
          unless owner.empty?
            body_scope = CensusScope.census_body_scope(default_scope, enclosing_prefix,
                                                       Type::Combinator.singleton_of(owner))
          end
          rvalue_type = meta_new_constant_type(node, full) ||
                        EmptySeed.erase(node.value, body_scope.type_of(node.value))
          existing = accumulator[full]
          accumulator[full] = existing ? Type::Combinator.union(existing, rvalue_type) : rvalue_type
        end

        # The accumulator key for a `Foo::BAR = …`. Ruby resolves the path's NAMESPACE through the nesting at
        # the write site, so `Holder::DEFAULT = …` inside `module Admin` names `Admin::Holder::DEFAULT`
        # whenever `Admin::Holder` is a class or module some source declares. Filing the entry under the
        # as-written spelling put it where no read of the resolved name reaches it: a read spelled
        # `Admin::Holder::DEFAULT` answered `Dynamic[top]`, and the in-namespace spelling fell past the
        # qualified rung of the lexical ladder to the bare one, hit the mis-keyed entry, and got a top-level
        # constant of the same name — `call.undefined-method` on correct code ([#690](https://github.com/rigortype/rigor/issues/690)).
        #
        # Two static forms keep the as-written key because their namespace is not the enclosing one: a write at
        # the top level, and a rooted `::Foo::BAR`, which names the top level by definition. Re-qualifying a
        # namespace the code does not name would file the entry under a guess.
        #
        # A target that renders no static path is NOT a third such form, and must not be handled by rendering
        # it leniently. `self::BAR = …` names whatever `self` is at that point — the enclosing declaration in
        # an ordinary body, the receiver inside a `class_eval` block ([#705](https://github.com/rigortype/rigor/issues/705)),
        # which is why `self_owner` travels with the walk rather than being read off `qualified_prefix`. Any
        # other dynamic base (`klass::BAR`) is attributable to no namespace at all and is DECLINED:
        # `qualified_name`'s lenient render drops the dynamic segment and yields the bare trailing name, so
        # recording it filed a value under a name the write never touched — and once the rvalue is typed under
        # the enclosing nesting, that bare key outranks an RBS top-level constant declaration and hands every
        # reader of the top-level name a receiver Ruby never names there.
        def constant_path_write_key(target, qualified_prefix, default_scope, self_owner = nil)
          return Source::ConstantPath.qualified_name(target) if Source::ConstantPath.rooted?(target)

          written = Source::ConstantPath.qualified_name_or_nil(target)
          return dynamic_base_write_key(target, qualified_prefix, self_owner) if written.nil?
          return written if qualified_prefix.empty?

          namespace, _, base = written.rpartition("::")
          return written if namespace.empty?

          "#{resolved_write_namespace(namespace, qualified_prefix, default_scope)}::#{base}"
        end

        # The key for a path write whose base is not a static constant path: the name `self` carries for a
        # `self::BAR = …`, and nil — decline to record the write at all — for every other dynamic base.
        def dynamic_base_write_key(target, qualified_prefix, self_owner = nil)
          return nil unless (tail = DeclarationWalk::Rules.self_anchored_tail(target))

          self_write_name(qualified_prefix, self_owner, tail.join("::"))
        end

        # The qualified name a `self::BAR = …` writes. `self_owner` is nil in the ordinary case — `self` is the
        # enclosing declaration, so the write takes the key a bare `BAR = …` in the same body takes — a class or
        # module name where a `class_eval`-family block rebound `self` to one, and {OPAQUE_SELF} where it
        # rebound `self` to something unnameable, which declines the write (nil) rather than filing it under a
        # namespace Ruby did not touch ([#705](https://github.com/rigortype/rigor/issues/705)).
        #
        # `Object` is the one owner that is not a namespace of its own: its constants ARE the top-level ones, and
        # every other census key spells those bare. Keying `Object::T` would file the write beside a sibling's
        # plain `T = 2` instead of on top of it, so the conflict between them goes undetected and one of the two
        # values publishes — the direction this whole issue is about.
        def self_write_name(qualified_prefix, self_owner, base)
          return qualified_write_name(qualified_prefix, base) if self_owner.nil?
          return nil if self_owner.equal?(OPAQUE_SELF)
          return base if self_owner == OBJECT_OWNER

          "#{self_owner}::#{base}"
        end

        # The namespace of a `Foo::BAR = …`, resolved the way a READ of the same spelling resolves it: the
        # first `<nesting entry>::Foo` that names a known class or module, innermost first, and the as-written
        # name when none does. Only class/module knowledge participates — a value constant owns no constants —
        # and the ancestor rung {Reflection.resolve_constant_type} walks is deliberately skipped, so a
        # namespace no source declares keeps the key it has today rather than moving to a guess.
        def resolved_write_namespace(namespace, qualified_prefix, scope)
          CensusScope.census_nesting(scope, qualified_prefix).each do |entry|
            candidate = "#{entry}::#{namespace}"
            return candidate if known_namespace?(candidate, scope)
          end
          namespace
        end

        # True when `name` is a class or module some source declares: a project declaration in
        # `discovered_classes` or an RBS-known class object. The [#528](https://github.com/rigortype/rigor/issues/528)
        # synthesized namespace prefixes reach that table for THIS FILE only — the runner's cross-file seed
        # (`discovered_project_index_for_paths`) returns `ClassDeclarations.collect_class_decls`'s raw declarations
        # without the synthesis its sibling `discovered_classes_for_paths` applies — so a namespace known only through
        # ANOTHER file's COMPACT declaration (`class Admin::Holder::Inner`) does not move the key, where an explicit
        # `module Admin; class Holder` there does. Under-resolution, the direction this probe may err in.
        #
        # The RBS half needs no dependency edge — the loaded signature set is part of the run fingerprint — but
        # both project answers do; see {.record_namespace_probe}.
        def known_namespace?(name, scope)
          if scope.discovered_classes.key?(name)
            record_namespace_probe(name, scope, hit: true)
            return true
          end

          environment = scope.environment
          return true if !environment.nil? && !environment.singleton_for_name(name).nil?

          record_namespace_probe(name, scope, hit: false)
          false
        end

        # ADR-46 — the key this census files a path write under is a function of ANOTHER file's class
        # declarations, and no edge the READER records covers it: a reference's negative key is
        # `class:<last segment>` of the name that failed to resolve, whereas here the write's key moves because
        # a MIDDLE segment appeared (`Holder::DEFAULT` inside `module Admin` starts naming
        # `Admin::Holder::DEFAULT` the moment some file declares `Admin::Holder`). Both directions therefore
        # need their own edge, recorded where the probe happens: a POSITIVE one on the file declaring the
        # namespace we resolved through, so deleting it moves the key back, and a NEGATIVE `class:` one on
        # every candidate that missed, so declaring it later moves the key forward. Without them a warm
        # incremental run serves a cached answer computed against a namespace that has since appeared. Gated on
        # the recorder, which is off on every ordinary run.
        def record_namespace_probe(name, scope, hit:)
          return unless Analysis::DependencyRecorder.active?

          if hit
            scope.discovered_class_sources[name]&.each { |site| Analysis::DependencyRecorder.read_site(site) }
          else
            Analysis::DependencyRecorder.read_missing(:class, name.split("::").last)
          end
        end

        # Survey item (e): when the rvalue is a recognised `Module.new do ... end` / `Class.new do ... end` /
        # `Struct.new(*sym) do ... end` / `Data.define(*sym) do ... end` form, type the named constant as
        # `Singleton[<full>]` so the discovered-method table registered under `full` becomes reachable through
        # singleton-side dispatch (`Const.[]=` etc.). Returns nil for non-meta-new rvalues so the caller falls back to
        # the default `body_scope.type_of(node.value)` shape.
        def meta_new_constant_type(node, full)
          return nil unless DeclarationWalk::Rules.meta_new_block_body(node)

          Type::Combinator.singleton_of(full)
        end

        # Issue #644 — the cross-file VALUE-constant pre-pass, the twin of {ScopeIndexer.record_class_sources} for plain
        # constant ASSIGNMENTS. Returns one file's **publication census**: `{qualified name => descriptor}`,
        # where the descriptor is `[literal]` (a publishable frozen scalar), {CONSTANT_MEMO}, or
        # {CONSTANT_UNPUBLISHABLE}.
        #
        # EVERY constant write is censused, whatever its rvalue and whatever its form, because the census is
        # four things at once and only the first cares about the value:
        #
        # 1. the published table ({ScopeIndexer.finalize_constant_writes}: a name publishes only when exactly one file
        #    writes it and that write is a literal),
        # 2. the attribution the ADR-46 positive edge reads,
        # 3. the producer whose per-file DIFF re-checks readers on an incremental run
        #    ({Analysis::Incremental.changed_constant_publications}), and
        # 4. the writes a constant compound write finds its binding among when its plain read resolves nothing
        #    ({Scope#bound_constant_names}), which is why a `||=`-only name carries its own descriptor.
        #
        # A write the census cannot see does not merely lose precision — it silently bypasses the conflict rule
        # and publishes a value the program does not have. That is why the operator / multi-assign / chained /
        # `self::` forms below are censused as unpublishable rather than skipped.
        #
        # **Why only Symbol / Integer / Float / `true` / `false` publish.** Publishing turns `Dynamic[top]` into a
        # real type at every reader in the project, which is precisely where a wrong answer becomes a diagnostic
        # on correct code (AGENTS.md § "Implementation Guidelines"), so the recognised set is the one whose
        # precision is worth that risk.
        #
        # - `String` / `Array` / `Hash` literals are MUTABLE. A sibling file's `PATH << "/x"` or `LIST.push(...)`
        #   moves the value this table pinned, and only the DECLARING file's
        #   `MutatedCarrierWidening.widen_mutated_constants` census can see such a mutation. The composite two
        #   additionally carry the `HashShape` / `Tuple` hazard
        #   {PreEvalConstants} documents (a closed `HashShape` makes `CONFIG.fetch(:b)` fire; a `Tuple` routes
        #   through `ShapeDispatch` instead of the RBS overload a call site relied on).
        # - `nil` declines for {PreEvalConstants}' reason: at declaration position it is a placeholder for a
        #   value assigned later far more often than it is a genuine `NilClass`.
        # - `true` / `false` DO publish. They are branched on rather than dispatched to, so the value would fuel
        #   `flow.always-truthy-condition` at every `if FEATURE_FLAG` in another file; that is withheld at the
        #   rule instead ({Analysis::CheckRules::PublishedConstantGuard}), which is the repo's own answer to a
        #   value that is real but must not be concluded from, and it keeps the treatment of every published
        #   kind the same.
        #
        # Everything else — a method call, a constant alias, `ENV[...]`, a `Data.define` — is not a literal, so
        # the reader keeps today's `Dynamic[top]`. Declining is always the safe answer.
        #
        # A name written TWICE in one file is unpublishable too, which is what makes a conditional
        # `X = :a if c` / `X = :b` pair gradual rather than pinned to whichever arm the walk saw first.
        def constant_writes_for_file(root) = constant_write_census(root).writes

        # The tables one file's publication census fills in a single walk, carried together so the walk's two
        # `self`-tracking parameters stay within the signature budget. `writes` is the census itself; `seen`
        # the names already recorded, so a repeat write retracts whatever either rvalue was; `declared` the
        # subset whose write NAMES its target, which is the only half {Scope#local_constant_names} may exempt
        # ([#710](https://github.com/rigortype/rigor/issues/710)).
        # `aliases` is `{qualified target name => the constant reference its rvalue names}` for the one
        # unpublishable rvalue shape whose provenance is still knowable ([#667](https://github.com/rigortype/rigor/issues/667)):
        # a plain `MODE2 = AppConfig::MODE`. The census cannot publish a VALUE for it — resolving the source
        # is the typed walk's job, not this syntactic one — but it can record that the name is a rename of
        # another, which is all the withholding guard needs. `write_census` is issue #1367's {GlobalWriteCensus}, fed
        # the same nodes; a node outside every named `class` / `module` body counts as top-level.
        CensusTables = Data.define(:writes, :seen, :declared, :aliases, :write_census)
        private_constant :CensusTables

        def constant_write_census(root)
          tables = CensusTables.new(writes: {}, seen: Set.new, declared: Set.new, aliases: {},
                                    write_census: GlobalWriteCensus::Collector.new(InEffectRefinements.new(root)))
          walk_constant_write_census(root, [], tables)
          tables
        end

        # Mirrors {.walk_constant_writes}'s traversal for the forms it shares — the lexical class/module prefix
        # qualifies a bare `ConstantWriteNode` — and extends it to the forms that walk misses, each censused as
        # unpublishable: an operator / `&&=` / `||=` constant write, a constant target wherever Prism holds one
        # (see {.census_constant_target}), a `self::X =` whose target renders no qualified name, and the inner
        # write of a chain (`C = D = :x`), which is why a `ConstantWriteNode` descends into its own rvalue instead
        # of returning.
        def walk_constant_write_census(node, qualified_prefix, tables, self_owner = nil, meta_owner = nil,
                                       singleton_cref: false)
          return unless node.is_a?(Prism::Node)

          # #1154 — the class whose instance `def`s the ivar-writer census credits; none under `class << self`.
          ivar_owner = census_ivar_owner(qualified_prefix, self_owner, singleton_cref)
          case node
          when Prism::SingletonClassNode
            # #1154 — a `class << self` inside an instance `def` opens the instance's singleton class.
            tables.write_census.visit(node, top_level: qualified_prefix.empty?, owner: ivar_owner)
            return walk_census_singleton_class(node, qualified_prefix, tables, self_owner,
                                               meta_owner, singleton_cref)
          when Prism::ClassNode, Prism::ModuleNode
            return walk_census_declaration(node, qualified_prefix, tables, self_owner, meta_owner,
                                           singleton_cref)
          else
            census_constant_write(node, qualified_prefix, tables, self_owner, singleton_cref: singleton_cref)
            tables.write_census.visit(node, top_level: qualified_prefix.empty?, owner: ivar_owner,
                                            receiver_owner: census_receiver_owner(node, qualified_prefix, self_owner))
          end

          rebound = rebound_block_self(node, qualified_prefix, nil, meta_owner, self_owner)
          # A `ConstantWriteNode`'s only child is its rvalue, so this reaches exactly the call whose block the
          # constant names — and nil everywhere else, leaving every other descent as it was.
          #
          # Issue #963 — except where a `.freeze` tail sits BETWEEN the two. The write names the class one hop
          # further down than it used to, so the name is carried through the tail rather than dropped at it;
          # otherwise the factory call arrives with no owner and {.rebound_block_self} answers {OPAQUE_SELF},
          # suppressing every `self::X = …` the block publishes. Only a tail passes the name on: a nil
          # `child_meta_owner` at any other node still means "this node names nothing".
          # Under an unnameable cref only a definite path write (`::K`, `C::K`) still names
          # its class; a bare `Klass = Class.new` keeps the opaque self instead of a
          # fabricated lexical owner.
          child_meta_owner =
            if singleton_cref
              meta_new_owner_under_cref(node, qualified_prefix)
            else
              meta_new_block_owner(node, qualified_prefix)
            end
          child_meta_owner ||= meta_owner unless DeclarationWalk::Rules.unwrap_freeze_tail(node).equal?(node)
          node.rigor_each_child do |child|
            rebinds_self = rebound && child.is_a?(Prism::BlockNode)
            owner = rebinds_self ? rebound : self_owner
            # `Module.nesting` never rebinds — the cref flag passes through a self-rebinding
            # block unchanged while `self` (and `self::` resolution) follows the receiver.
            walk_constant_write_census(child, qualified_prefix, tables, owner, child_meta_owner,
                                       singleton_cref: singleton_cref)
          end
        end

        # #1154 — the class whose instance `def`s the ivar-writer census credits: the class a `Struct.new` /
        # `Data.define` / `Class.new` constant or a `K.class_eval` block opens (`self_owner`), else the lexical class;
        # none under `class << self` or an opaque block. The prefix Array is joined only when an entry is recorded.
        def census_ivar_owner(qualified_prefix, self_owner, singleton_cref)
          return self_owner if self_owner.is_a?(String)
          return nil if self_owner || singleton_cref || qualified_prefix.empty?

          qualified_prefix
        end

        # Issue #2488 — the class an explicit-receiver writer call (`E.attr_writer :w`, `E.define_method(:m) { … }`)
        # names, resolved as a `class_eval` receiver is in this census (keyed as written), or nil.
        def census_receiver_owner(node, qualified_prefix, self_owner)
          receiver = ReceiverWriterCall.receiver(node)
          return nil if receiver.nil?

          name = eval_receiver_self(receiver, qualified_prefix, nil, rebound_self_base(self_owner))
          name if name.is_a?(String)
        end

        # Under an unnameable cref a bare/`self::` header pushes `#<singleton>::Name` — still
        # unnameable — so the body keeps the OPAQUE self and the cref flag; nameable
        # headers re-anchor at a real cref.
        def walk_census_declaration(node, qualified_prefix, tables, self_owner, meta_owner,
                                    singleton_cref)
          rebound_self = meta_owner || self_owner
          self_base =
            case rebound_self
            when String then [rebound_self]
            when Symbol then [] # OPAQUE_SELF — a `self::` header names nothing
            end
          # Issue #3407 — the header runs under the enclosing cref, before the body opens: a write in a dynamic
          # header path (`class (A = M)::B`) or in the superclass expression (`class C < (A = Base)`) lands there.
          walk_constant_write_census(node.constant_path, qualified_prefix, tables, self_owner, meta_owner,
                                     singleton_cref: singleton_cref)
          if node.is_a?(Prism::ClassNode)
            walk_constant_write_census(node.superclass, qualified_prefix, tables, self_owner, meta_owner,
                                       singleton_cref: singleton_cref)
          end
          self_decl = DeclarationWalk::Rules.self_anchored_decl_prefix(node.constant_path, self_base)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return unless child_prefix && node.body

          child_cref = DeclarationWalk::Rules.unnameable_decl?(node, self_decl, singleton_cref)
          # The body keeps the enclosing prefix, not `child_prefix`: `#<singleton>::D` is a
          # real cref rung, but the only NAMEABLE rungs below it are the enclosing ones —
          # `Foo::BAR` inside resolves through `C::Foo`/`::Foo`, never a spelled `C::D::Foo`.
          walk_constant_write_census(node.body, child_cref ? qualified_prefix : child_prefix, tables,
                                     child_cref ? OPAQUE_SELF : nil, singleton_cref: child_cref)
        end

        # `self` inside a `class <<` body is the singleton: `self`-anchored and bare write
        # targets land on its constant table (unnameable, so both decline) and a
        # `self::`-anchored eval receiver raises NameError at runtime, so the body is entered
        # with an OPAQUE self. The lexical cref below it is unnameable too — the flag only
        # lifts at a `::`-rooted class/module header.
        def walk_census_singleton_class(node, qualified_prefix, tables, self_owner, meta_owner,
                                        singleton_cref)
          walk_constant_write_census(node.expression, qualified_prefix, tables, self_owner,
                                     meta_owner, singleton_cref: singleton_cref)
          return unless node.body

          walk_constant_write_census(node.body, qualified_prefix, tables, OPAQUE_SELF,
                                     meta_owner, singleton_cref: true)
        end

        # Censuses `node` when it is any constant-assigning form. Only a plain `ConstantWriteNode` /
        # `ConstantPathWriteNode` can contribute a VALUE; every other form is recorded unpublishable, which
        # suppresses publication of the name exactly as a second file's write would.
        # Writes inside a `class <<` body (`singleton_cref`) to a bare or `self`-anchored
        # target land on the singleton's own constant table — a name nothing else can
        # produce — so they record nothing rather than fabricating an enclosing-class name
        # or a wildcard retraction for a constant they cannot touch.
        def census_constant_write(node, qualified_prefix, tables, self_owner = nil,
                                  singleton_cref: false)
          case node
          when Prism::ConstantWriteNode
            return if singleton_cref

            record_constant_write_census(qualified_write_name(qualified_prefix, node.name.to_s),
                                         constant_literal_value(node.value), tables,
                                         alias_of: constant_alias_source(node.value))
          when Prism::ConstantPathWriteNode
            return if singleton_cref && singleton_self_write?(node.target, self_owner)

            record_constant_write_census(constant_path_write_name(node.target, qualified_prefix, self_owner),
                                         constant_path_write_literal(node, self_owner), tables,
                                         nameable: nameable_write_target?(node.target, self_owner),
                                         alias_of: constant_alias_source(node.value))
          when Prism::ConstantOperatorWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode
            return if singleton_cref

            record_constant_write_census(qualified_write_name(qualified_prefix, node.name.to_s), nil, tables,
                                         memo: node.is_a?(Prism::ConstantOrWriteNode))
          when Prism::ConstantPathOperatorWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode
            census_path_write(node, qualified_prefix, tables, self_owner, singleton_cref: singleton_cref)
          when Prism::ConstantTargetNode, Prism::ConstantPathTargetNode
            census_constant_target(node, qualified_prefix, tables, self_owner, singleton_cref: singleton_cref)
          end
        end

        def census_path_write(node, qualified_prefix, tables, self_owner, singleton_cref: false)
          return if singleton_cref && singleton_self_write?(node.target, self_owner)

          record_constant_write_census(constant_path_write_name(node.target, qualified_prefix, self_owner),
                                       nil, tables,
                                       nameable: nameable_write_target?(node.target, self_owner),
                                       memo: node.is_a?(Prism::ConstantPathOrWriteNode))
        end

        # A `self`-anchored write target under a self the walk cannot name — inside `class <<`
        # the read raises NameError or lands on the singleton's table, never on a constant the
        # census could spell, so it declines rather than laying a wildcard retraction down.
        def singleton_self_write?(target, self_owner)
          self_owner == OPAQUE_SELF && !DeclarationWalk::Rules.self_anchored_tail(target).nil?
        end

        # Issue #3407 — a constant target, reached by the walk's ordinary descent wherever Prism holds one: a
        # multiple assignment's lefts, rights and splat (`A, *B = …`), a nested target list (`(A, B), c = …`), a
        # `for` index (`for A in …`) and a `rescue => A` reference. Prism's node set puts a target in no other
        # position: a pattern capture and a block parameter bind locals only. A target's value is a projection or
        # a runtime value this syntactic walk does not evaluate, so every one is censused unpublishable. A path
        # target is keyed by {.constant_path_write_name}, which renders no `ConstantPathTargetNode` and so files
        # it under the wildcard key, the over-retracting direction.
        def census_constant_target(target, qualified_prefix, tables, self_owner = nil, singleton_cref: false)
          if target.is_a?(Prism::ConstantTargetNode)
            return if singleton_cref

            record_constant_write_census(qualified_write_name(qualified_prefix, target.name.to_s), nil, tables)
          else
            return if singleton_cref && singleton_self_write?(target, self_owner)

            record_constant_write_census(constant_path_write_name(target, qualified_prefix, self_owner),
                                         nil, tables, nameable: nameable_write_target?(target, self_owner))
          end
        end

        # The qualified name a constant-path write targets, for the PUBLICATION census only. `Foo::BAR = …`
        # renders as written — deliberately NOT what {.constant_path_write_key} answers for the typed table,
        # which resolves the namespace through the enclosing nesting
        # ([#690](https://github.com/rigortype/rigor/issues/690)). Moving this one changes which name a value
        # publishes to the whole project, an over-suppression question with its own safety story, so the two
        # censuses key a path write differently until that is settled.
        # `self::BAR = …` names whatever `self` is at that point, which the walk carries in `self_owner`
        # ([#705](https://github.com/rigortype/rigor/issues/705)) — the enclosing lexical namespace in an
        # ordinary body, the receiver inside a `class_eval` block, and the constant a `Klass = Class.new { … }`
        # assigns the block's class to ({.meta_new_block_owner}). Where that `self` is {OPAQUE_SELF}, and for
        # any other dynamic receiver (`klass::BAR = …`), the target is "some class, then `::BAR`" and the name
        # falls back to the WILDCARD {DYNAMIC_TARGET_PREFIX} key, which {ScopeIndexer.finalize_constant_writes} expands
        # into a retraction of every censused name with that last segment
        # ([#668](https://github.com/rigortype/rigor/issues/668)). The bare last segment — the pre-#668
        # fallback — was the single name such a write can never create, so filing it there suppressed the one
        # name the form cannot touch and left published every name it can. The VALUE is what such a write must
        # not contribute either ({.constant_path_write_literal}), and the fallback name is withheld from the
        # local-declaration exemption ({ScopeIndexer.local_constant_name_set}).
        def constant_path_write_name(target, qualified_prefix, self_owner = nil)
          full = Source::ConstantPath.qualified_name_or_nil(target)
          return full if full

          base = target.name&.to_s
          return nil if base.nil?
          return dynamic_target_key(base) unless (tail = DeclarationWalk::Rules.self_anchored_tail(target))

          self_write_name(qualified_prefix, self_owner, tail.join("::")) || dynamic_target_key(base)
        end

        def dynamic_target_key(segment) = "#{DYNAMIC_TARGET_PREFIX}#{segment}"

        # The publishable literal a path write contributes — none, whenever its base is not statically
        # nameable ([#705](https://github.com/rigortype/rigor/issues/705)). `[Foo].each { |k| k::X = 1 }`
        # renders under the wildcard key, and publishing `1` there handed every reader of a project `X` a value
        # the program never has: `X == 2` folded to `false`, and in the WRITING file — where
        # `Scope#local_constant_names` exempts the name from #644's withholding guard —
        # `flow.always-truthy-condition` then fired on correct code.
        #
        # The NAME still enters the census, because a decline means opposite things in the two censuses. In the
        # typed one, recording no type is gradual. Here, recording nothing would leave ANOTHER file's value for
        # the name trusted — silence is the risky direction, and the census's own gradual answer is to say the
        # name was touched and no value for it is safe.
        def constant_path_write_literal(node, self_owner)
          return nil unless nameable_write_target?(node.target, self_owner)

          constant_literal_value(node.value)
        end

        # True when the census can name what the write targets: a static constant path, or a `self::BAR` whose
        # `self` the walk resolved to a class or module.
        def nameable_write_target?(target, self_owner)
          return true if Source::ConstantPath.qualified_name_or_nil(target)
          return false unless DeclarationWalk::Rules.self_anchored_tail(target)

          !self_owner.equal?(OPAQUE_SELF)
        end

        def qualified_write_name(qualified_prefix, base_name)
          qualified_prefix.empty? ? base_name : "#{qualified_prefix.join('::')}::#{base_name}"
        end

        # Records one censused write. `seen` carries the names this file has already written, so a repeat write
        # retracts the publishable descriptor whatever either rvalue was — neither arm of an in-file
        # reassignment is ever published, and the name still counts as written.
        #
        # `nameable` is false only for the wildcard fallback {.constant_path_write_name} takes when nothing
        # names the write's base. Such a key belongs in `writes` — another file's value for a name it reaches
        # is not to be trusted — and NOT in `declared`, which answers the opposite question
        # ([#710](https://github.com/rigortype/rigor/issues/710)). The two are separate tables rather than one
        # richer descriptor because a name can be written both ways in one file, and then the file DID declare
        # it however the two writes are ordered.
        #
        # `memo` marks a `||=` write, which files {CONSTANT_MEMO} for as long as every write of the name in this
        # file is one.
        def record_constant_write_census(full, literal, tables, nameable: true, alias_of: nil, memo: false)
          return if full.nil?

          tables.declared << full if nameable
          first_write = tables.seen.add?(full)
          tables.writes[full] = census_descriptor(tables.writes[full], first_write, literal, memo)
          record_constant_alias_census(full, alias_of, tables, first_write && nameable)
        end

        def census_descriptor(previous, first_write, literal, memo)
          return literal || (memo ? CONSTANT_MEMO : CONSTANT_UNPUBLISHABLE) if first_write

          memo && previous == CONSTANT_MEMO ? CONSTANT_MEMO : CONSTANT_UNPUBLISHABLE
        end

        # Issue #667 — a name written TWICE is not an alias of anything the walk can name, exactly as it is
        # unpublishable above; the `delete` is what retracts a first write's record when the second arrives.
        def record_constant_alias_census(full, alias_of, tables, keep)
          if keep && alias_of
            tables.aliases[full] = alias_of
          else
            tables.aliases.delete(full)
          end
        end

        # The constant reference an rvalue names, or nil when it names none. `AppConfig::MODE` renders
        # qualified; a path that renders no qualified name falls back to its own last segment, which is all
        # `Scope#published_constant?` can be asked about anyway.
        def constant_alias_source(rvalue)
          case rvalue
          when Prism::ConstantReadNode then rvalue.name.to_s
          when Prism::ConstantPathNode then Source::ConstantPath.qualified_name_or_nil(rvalue) || rvalue.name&.to_s
          end
        end

        # The frozen-scalar literal fold: `[value]` for a publishable rvalue, nil to decline. The one-element
        # Array is the presence wrapper (`false` is a legitimate published value), and the raw Ruby value is
        # what rides the ADR-85 seed bundle through `Marshal`.
        def constant_literal_value(rvalue)
          case rvalue
          when Prism::SymbolNode then symbol_literal_publication(rvalue)
          when Prism::IntegerNode, Prism::FloatNode then [rvalue.value]
          when Prism::TrueNode then [true]
          when Prism::FalseNode then [false]
          end
        end

        # `Prism::SymbolNode` is the STATIC symbol node (a dynamic `:"#{x}"` parses as
        # `InterpolatedSymbolNode` and never reaches here), so its unescaped text is the whole value.
        def symbol_literal_publication(node)
          text = node.unescaped
          text.is_a?(String) ? [text.to_sym] : nil
        end

        # The class name a meta-new write under an unnameable cref still assigns for the OWNER
        # tables (mixins, census) — only a definite `A::K = …` / `::K = …` write, matching
        # {.meta_new_block_owner}'s plain-write requirement for the same #963 reason (an `||=`
        # may never run the rvalue). Nil where the write names nothing.
        def meta_new_owner_under_cref(node, qualified_prefix, self_base = nil)
          return nil unless node.is_a?(Prism::ConstantPathWriteNode)
          return nil unless DeclarationWalk::Rules.meta_new_path_target_nameable?(node, self_base)

          DeclarationWalk::Rules.meta_new_child_prefix(node, qualified_prefix, self_base)&.join("::")
        end

        private_class_method :walk_constant_writes, :walk_singleton_class_writes, :walk_typed_declaration?,
                             :rebound_self_base, :walk_constant_write_children, :meta_new_block_owner,
                             :eval_receiver_self, :record_constant_write, :constant_path_write_key,
                             :dynamic_base_write_key, :self_write_name, :resolved_write_namespace, :known_namespace?,
                             :record_namespace_probe, :meta_new_constant_type, :constant_writes_for_file,
                             :walk_constant_write_census, :census_ivar_owner, :census_receiver_owner,
                             :walk_census_declaration, :walk_census_singleton_class, :census_constant_write,
                             :census_path_write, :singleton_self_write?, :census_constant_target,
                             :constant_path_write_name, :constant_path_write_literal, :nameable_write_target?,
                             :qualified_write_name, :record_constant_write_census, :census_descriptor,
                             :record_constant_alias_census, :constant_alias_source, :constant_literal_value,
                             :symbol_literal_publication, :meta_new_owner_under_cref
      end
    end
  end
end
