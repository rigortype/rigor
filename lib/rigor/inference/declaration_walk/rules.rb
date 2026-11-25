# frozen_string_literal: true

require "prism"

require_relative "../../memo_audit"
require_relative "../../source/constant_path"
require_relative "../../typing_state"

module Rigor
  module Inference
    module DeclarationWalk
      # The declaration-context rules (ADR-116 WD9): what a `class` / `module` header, a `K = Class.new { … }`-family
      # write and an eval-family block make of `self`, the cref and `Module.nesting`, with the recognisers and the
      # per-file oracle of declared names those answers rest on. It is the closure of the calls {Context} and
      # {Traversal} make for a rule, moved out of `scope_indexer.rb` whole. `ScopeIndexer`'s hand-written walkers, the
      # collectors under `scope_indexer/` and the other files that ask a rule call the same functions, as
      # `DeclarationWalk::Rules.x`.
      #
      # Every function is a module function of the positionals it is handed. The module holds no state of its own: its
      # one memo, the set of names a parse's source declares, is in the `TypingState` slot {DECLARED_NAMES} declares.
      # It names nothing of `ScopeIndexer`: a rule that needs a walker's answer takes it as an argument.
      # `spec/rigor/inference/declaration_walk/rules_spec.rb` pins the functions callable from outside and the constants
      # the module exports, as a list that may shrink and does not grow; an entry added here is an amendment to
      # ADR-116's WD9 section.
      #
      # `scope_indexer.rb` requires this file at the end of the `require_relative` block at its head. {DECLARED_NAMES}
      # is declared as the file loads, and that place keeps its index in `TypingState.slots`, which loading it from
      # `traversal.rb` would move. So `context.rb` and `traversal.rb` name {Rules} without requiring this file; they are
      # loaded through `rigor/inference/declaration_walk`.
      #
      # @api private
      module Rules # rubocop:disable Metrics/ModuleLength
        module_function

        # The scope a census walk threads into the body a `class` / `module` header opens: the scope it already
        # threads, carrying that body's real `Module.nesting`.
        #
        # Issue #708 — the qualified prefix stopped being sufficient to DERIVE that chain. A rooted header
        # RESETS the prefix (`class ::Rooted` inside `module Outer` prefixes `["Rooted"]`), so `Outer` is absent
        # from it entirely and no function of the prefix alone recovers it, while Ruby keeps `Outer` on the
        # ladder as a live rung. `Source::ConstantPath.pushed_nesting` — the one function both declaration walks
        # already push with — has that case right, so the chain travels on the scope these walks thread anyway
        # rather than through every walk's parameter list, and stays a single owner ([#652](https://github.com/rigortype/rigor/issues/652)).
        def scope_entering_declaration(default_scope, constant_path)
          return default_scope if default_scope.nil?

          chain = Source::ConstantPath.pushed_nesting(default_scope.lexical_nesting || EMPTY_NESTING,
                                                      constant_path)
          chain ? default_scope.with_lexical_nesting(chain) : default_scope
        end

        # Ruby's `Module.nesting` for a body enclosed by `qualified_prefix`, innermost first: each entry is the
        # prefix truncated at one declaration, joined, so the compact spelling contributes exactly one entry and
        # the nested spelling one per `class` / `module` keyword.
        #
        # **This is an approximation, and only correct when no ROOTED header encloses the body** — a rooted
        # header resets the prefix without resetting Ruby's nesting, so the entries beneath the reset are not
        # in the prefix to be truncated out of it (#708). It remains the answer for a caller that threaded no
        # chain, where it is what the code did before and never a new firing; the walks that reach a body
        # thread the real chain via {#scope_entering_declaration}.
        def lexical_nesting_for_prefix(qualified_prefix)
          (1..qualified_prefix.size).map { |n| qualified_prefix.first(n).join("::") }.reverse.freeze
        end

        # Issue #705 — the block-taking calls that swap `self` for the RECEIVER: Ruby evaluates the block with
        # the receiver as `self` and leaves `Module.nesting` untouched, so `self::BAR = …` inside one names the
        # receiver's `BAR` while a bare `BAR = …` in the same block still names the enclosing namespace's.
        SELF_REBINDING_EVAL_CALLS = %i[class_eval module_eval class_exec module_exec].freeze
        private_constant :SELF_REBINDING_EVAL_CALLS

        # `instance_eval` / `instance_exec` rebind `self` to the receiver exactly as `class_eval`
        # does — `X.instance_eval { self::BAR = 1 }` writes `X::BAR` — but the default definee moves
        # to the receiver's SINGLETON instead of the receiver: `X.instance_eval { def m }` installs
        # `X.m`, while `define_method`/`attr_*` inside (method calls on the receiver-as-module)
        # still install `X#m`. The def-owning walks split the two surfaces on this list.
        INSTANCE_EVAL_CALLS = %i[instance_eval instance_exec].freeze
        RECEIVER_EVAL_CALLS = (SELF_REBINDING_EVAL_CALLS + INSTANCE_EVAL_CALLS).freeze

        # The owner whose constants the census spells BARE — `Object`'s constants are the top-level ones.
        OBJECT_OWNER = "Object"

        # Whether `self` in this position names nothing a `self::` receiver or write target
        # can resolve against: inside `class <<` (self is the singleton), under a self an
        # eval declined to name (an explicit empty def-owner), or anywhere below an
        # unnameable lexical cref without an eval-derived self — a `class D` nested in
        # `class <<` reopens `#<Class:C>::D`, a real class object nothing can spell. A
        # nameable eval owner still answers: `Foo.class_eval { self::X = }` inside
        # `class <<` resolves `Foo::X`.
        def unnameable_eval_self?(in_singleton_class, def_owner_prefix, qualified_prefix, singleton_cref)
          return true if in_singleton_class
          return true if def_owner_prefix && def_owner_prefix.empty?

          singleton_cref && (def_owner_prefix || qualified_prefix).empty?
        end

        # v0.1.2 — when a `Const = Data.define(*sym) do ... end` / `Const = Struct.new(*sym) do ... end` constant write
        # carries a block, the block body holds method overrides whose canonical class is `Const`. Survey item (e)
        # extended the recognition to `Const = Module.new do ... end` and `Const = Class.new(?super) do ... end` — the
        # ADR-16 Tier A "block-as-method" idiom at constant-write position. Returns the block body node (a
        # `Prism::StatementsNode`) when the rvalue matches; nil otherwise. Used by
        # `ScopeIndexer#walk_methods_and_def_nodes` to push `Const` onto the qualified prefix before recursing.
        #
        # Issue [#703](https://github.com/rigortype/rigor/issues/703) — a PATH write is the same idiom.
        # `Holder::Thing = Struct.new(:a) do … end` inside a module is ordinary Ruby, and declining it here lost the
        # factory registration, the member layout and the block's own defs together: the constant answered
        # `singleton(Struct)` and its instance `Struct`, a class RBS knows, so every member read and every override
        # call fired `call.undefined-method` on code Ruby runs. The name the write gives the class is
        # {#meta_new_child_prefix}'s, so every walk that pushes it agrees.
        #
        # Issue [#963](https://github.com/rigortype/rigor/issues/963) — the spelling of the WRITE and the tail of the
        # rvalue are both incidental to the idiom, and both were load-bearing here. `Const = Struct.new(:a) do … end`
        # was recognised while `Const ||= Struct.new(:a) do … end` and `Const = Struct.new(:a) do … end.freeze` were
        # not, so the same body was walked as a class body in one spelling and left in the enclosing scope in the
        # other two. {#meta_new_block_call} owns both unwrappings; every walk asks it, so no spelling can be
        # recognised by one pass and missed by another.
        def meta_new_block_body(node)
          block = meta_new_block_call(node)&.block
          # A `&BODY` / `&:sym` block ARGUMENT is not a literal block: its body is unreadable here (#1816).
          block.body if block.is_a?(Prism::BlockNode)
        end

        # The class-creating call a constant write's rvalue ultimately is, or nil when the write is not the idiom.
        # The single recognition point for {#meta_new_block_body} and every caller that needs the CALL rather than
        # its body — `StatementEvaluator#eval_constant_write` enters the block through it, so the evaluator and the
        # index cannot disagree about which node opened the class body.
        def meta_new_block_call(node)
          rvalue = meta_new_rvalue(node)
          return nil unless rvalue.is_a?(Prism::CallNode) && meta_new_constant_rvalue?(rvalue)

          rvalue
        end

        # The four constant-write spellings that name the class their rvalue creates. `Const ||= …` is the
        # define-once idiom: where the constant is unset — the case the program is written for — Ruby evaluates the
        # rvalue and names the class `Const`, exactly as the plain write does. `&&=` and the operator writes are NOT
        # here: neither names a freshly created class.
        #
        # The six whole-tree walks that recognise the idiom spell these four classes out in their `when` arms rather
        # than splatting this list: `when *ARRAY` copies the array on EVERY evaluation, and the arms are evaluated once
        # per AST node per walk, which cost `rigor check lib` about 2.3M allocations (+10%) when they were splatted.
        # This list is for the `is_a?` scans; keep the arms and the list in step.
        META_CONSTANT_WRITE_NODES = [
          Prism::ConstantWriteNode,
          Prism::ConstantPathWriteNode,
          Prism::ConstantOrWriteNode,
          Prism::ConstantPathOrWriteNode
        ].freeze
        private_constant :META_CONSTANT_WRITE_NODES

        # The rvalue a recognised constant write assigns, with the two value-preserving wrappers stripped: a
        # `.freeze` tail (`Struct.new(:a) do … end.freeze` — `Module#freeze` returns the receiver, so the constant
        # still holds the class the call created) and a `Const = Const || Struct.new(…)` guard, the long spelling of
        # `||=`. Nil when `node` is not a constant write at all.
        def meta_new_rvalue(node)
          return nil unless META_CONSTANT_WRITE_NODES.any? { |kind| node.is_a?(kind) }

          unwrap_freeze_tail(unwrap_or_guard(node, node.value))
        end

        # `Const = Const || <rvalue>` carries the same meaning as `Const ||= <rvalue>`, and only when the guarded
        # name is the constant being written: `A = B || Struct.new(:x)` may hold `B`, whose class `A` does not name.
        def unwrap_or_guard(node, value)
          return value unless value.is_a?(Prism::OrNode)

          written = meta_constant_write_name(node)
          return value if written.nil?

          Source::ConstantPath.qualified_name_or_nil(value.left) == written ? value.right : value
        end

        # A `.freeze` tail, repeated (`freeze.freeze` is legal and idempotent). Only the receiverful, argumentless,
        # blockless call is unwrapped — anything else is a different method that may return a different object.
        # `&.freeze` is declined with them: its value is the receiver OR nil, and a rule that answers "the constant
        # holds the class the factory made" must not be stated over a shape whose value can be nil.
        def unwrap_freeze_tail(value)
          value = value.receiver while freeze_tail?(value)
          value
        end

        def freeze_tail?(value)
          value.is_a?(Prism::CallNode) && value.name == :freeze && !value.safe_navigation? &&
            value.receiver && value.arguments.nil? && value.block.nil?
        end

        # The name a recognised constant write assigns, as written (`Const`, `Holder::Thing`). Used only to compare
        # a `Const = Const || …` guard against its own target.
        def meta_constant_write_name(node)
          case node
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then node.name.to_s
          when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
            Source::ConstantPath.qualified_name_or_nil(node.target)
          end
        end

        # The qualified prefix a meta-new constant write names its class under, given the lexical prefix the write sits
        # in — the segments every scope-free pre-pass pushes before descending into the block, and the key
        # {ScopeIndexer#record_meta_new_constant?} files the discovered class under. Nil for a target that is neither
        # form.
        #
        # A PATH write takes exactly what a compact `class Holder::Thing` header at the same position takes
        # ({Source::ConstantPath.declaration_prefix}), rooted reset included. These pre-passes run before any scope
        # exists, so the namespace cannot be resolved the way {ScopeIndexer#constant_path_write_key} resolves it for the
        # typed table — but the two land on the same name anyway, because registering `Admin::Holder::Thing` here is
        # what makes `Admin::Holder` a namespace {ScopeIndexer#resolved_write_namespace} knows.
        #
        # Where the namespace is NOT under the enclosure — a top-level `Loner` written as `Loner::Made = Struct.new(…)`
        # inside `module Admin` — that qualification is a guess, and {ScopeIndexer#synthesize_namespace_prefixes} then
        # answers a read of `Loner` there with the `Admin::Loner` it invented. That is the same answer the equivalent
        # `class Loner::Made` header has always produced, from the same two functions: the two spellings of one
        # declaration stay consistent rather than one of them carrying a second approximation of its own.
        #
        # Issue #963 — `Const ||= …` names its class exactly as `Const = …` does, so the two or-write spellings take
        # the branch of the write shape they are the conditional form of.
        # `self_base` names the rebound self for a `self::`-anchored target — inside a
        # meta-new block `self` is the class the write names, so `self::X = Class.new`
        # opens `K::X`, not the lexical `X`.
        def meta_new_child_prefix(node, qualified_prefix, self_base = nil)
          case node
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode
            qualified_prefix + [node.name.to_s]
          when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
            target = node.target
            if self_anchored_tail(target)
              # A `self::` target anchors on the rebound self when one is named; nil
              # `self_base` means `self` IS the lexical enclosure, so the lenient render
              # is the right name — `self::S = Class.new` inside `class C` is `C::S`.
              self_anchored_decl_prefix(target, self_base) ||
                (self_base.nil? &&
                 Source::ConstantPath.declaration_prefix(qualified_prefix, target))
            else
              # Any other base must render a real constant path — `var::K = Class.new`
              # writes whatever `var` holds, a class no source spelling reaches, so the
              # lenient `declaration_prefix` render (`C::K`) would be a name the write
              # never produced.
              Source::ConstantPath.qualified_name_or_nil(target) &&
                Source::ConstantPath.declaration_prefix(qualified_prefix, target)
            end
          end
        end

        # The three contexts a `K = Class.new { … }`-shaped write hands its children: the
        # factory call's receiver and arguments evaluate in the ENCLOSING self and cref —
        # the write has not landed yet — while the block body's `self` is the class the
        # write names (`child_prefix`, or `[]` when the write names nothing below an
        # unnameable cref or a dynamic base) and its `Module.nesting` stays lexical.
        # Returns `[enclosing_parts, body, body_self]`; nil when the rvalue opens no
        # recognised meta-new block. `self_base` names a rebound enclosing self for a
        # `self::` write target.
        def meta_new_block_split(node, qualified_prefix, self_base, singleton_cref)
          call = meta_new_block_call(node)
          return nil unless call

          child_prefix = meta_new_child_prefix(node, qualified_prefix, self_base)
          body_self =
            if singleton_cref && !meta_new_path_target_nameable?(node, self_base)
              []
            else
              child_prefix || []
            end
          enclosing = [call.receiver, *call.arguments&.arguments.to_a].compact
          [enclosing, meta_new_block_body(node), body_self]
        end

        # The three values an eval-family block gives a leaf walk: the receiver and arguments
        # that keep the enclosing context, the block body, and the rebound self's prefix —
        # `[]` when the receiver names nothing. `def`-family leaves and `self::` declarations
        # anchor on the third value while `Module.nesting` stays lexical, so the walk keeps
        # `qualified_prefix` for declarations and swaps only the def-owner channel.
        def eval_block_split(node, qualified_prefix, self_owner, singleton_cref)
          return nil unless receiver_eval_call?(node)

          self_prefix = self_owner || qualified_prefix
          unnameable = unnameable_eval_self?(false, self_owner, qualified_prefix,
                                             singleton_cref)
          eval_prefix = eval_receiver_prefix(node, self_prefix, qualified_prefix,
                                             unnameable_self: unnameable) || []
          # An unnameable enclosing self — a `class <<` body, an ownerless eval or factory
          # block — means a bare/`self`/`self::` receiver names nothing these leaf tables can
          # key on; `eval_receiver_prefix` still answers `self_prefix` for the bare form, so
          # the ownerless marker is applied here.
          eval_prefix = EMPTY_PREFIX if unnameable && !eval_named_receiver?(node)
          [[node.receiver, *node.arguments&.arguments.to_a].compact, node.block.body, eval_prefix]
        end

        # The wider form: any call whose block rebinds `self` to the receiver — `instance_eval` and
        # `instance_exec` included. Walks that read `self`-anchored facts use this gate; walks that
        # own `def` leaves additionally split on {INSTANCE_EVAL_CALLS}, whose `def`s bind on the
        # receiver's singleton rather than the receiver.
        def receiver_eval_call?(node)
          node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) && RECEIVER_EVAL_CALLS.include?(node.name)
        end

        # The owner an eval-family block body evaluates under, given the enclosing body's SELF
        # prefix — `def_owner_prefix || qualified_prefix` at the call sites, because `self`
        # inside an eval body is the enclosing eval's receiver, not the lexical class — and the
        # LEXICAL prefix, which answers the constant-receiver case: constant lookup in an eval
        # body stays lexical, so `Y.class_eval` written inside `M::Y.class_eval` at top level
        # re-opens the TOP-LEVEL `Y`, never `M::Y` again (a class is not a member of its own
        # constant table). A bare or `self` receiver keeps the enclosing self — `class_eval`'s
        # self IS the block's self — and a constant receiver names its own class, the same
        # convention {ScopeIndexer#singleton_class_prefix} applies to `class <<`. A receiver that renders no
        # static path — a variable, a call, a dynamic-base `expr::Bar` — is DECLINED like
        # {ScopeIndexer#constant_path_write_key} declines dynamic write targets: `qualified_name`'s lenient
        # render would drop the dynamic segment and file the body's defs under a class the eval
        # never opened.
        def eval_receiver_prefix(node, self_prefix, lexical_prefix, unnameable_self: false)
          receiver = node.receiver
          return self_prefix if receiver.nil? || receiver.is_a?(Prism::SelfNode)

          # `self::Foo` / `self::Foo::Bar` names the enclosing self's path — the same
          # resolution {ScopeIndexer#constant_path_write_key} gives a `self::` write target. When the
          # enclosing self names nothing ({#unnameable_eval_self?}) the read raises
          # NameError at runtime unless the constant lives on that self — so the receiver
          # declines rather than filing the body under the lexical class.
          if (tail = self_anchored_tail(receiver))
            return nil if unnameable_self

            return collapse_object_owner(self_prefix + tail)
          end

          rendered = Source::ConstantPath.qualified_name_or_nil(receiver)
          return nil unless rendered

          eval_constant_receiver_prefix(node, receiver, rendered, lexical_prefix)
        end

        # The tail of {#eval_receiver_prefix} once the receiver renders a static
        # constant name — also the `class << Y` operand's resolution
        # ({ScopeIndexer#singleton_class_prefix}), which follows the same lexical rule.
        #
        # A `::`-rooted receiver names the top level — `::B` inside `class A::B`
        # is still `B`, so the root check precedes both the self-reopen shortcut
        # and the lexical walk ({Source::ConstantPath}'s contract: callers doing
        # Ruby's lexical constant lookup MUST consult `rooted?` out of band). An
        # unqualified (or partially-qualified) receiver then resolves through
        # `Module.nesting` — `X` inside `class S` names `S::X` whenever that
        # constant exists — so the first `<nesting entry>::X` the file declares
        # wins, innermost first, and the as-written name stands when no rung
        # declares it: the same `<entry>::<first segment>` walk
        # {ScopeIndexer#resolved_write_namespace} performs for a `Foo::BAR = …` namespace,
        # against the same segment-approximation {lexical_nesting_for_prefix}
        # gives when no scope carries the real chain. A `S::X` declared only in
        # ANOTHER file still resolves as-written — the set
        # {#eval_file_declared_names} consults is the defining file's own answer,
        # matching the `in_source_constants` limitation {ScopeIndexer#resolved_write_namespace}
        # documents.
        def eval_constant_receiver_prefix(node, path_node, rendered, lexical_prefix)
          # `class << ::X = expr` spells its root on the write's target, not the
          # write node itself.
          path_node = path_node.target if path_node.is_a?(Prism::ConstantPathWriteNode)
          return rendered.split("::") if Source::ConstantPath.rooted?(path_node)
          return rendered.split("::") if lexical_prefix.empty?
          return lexical_prefix if lexical_prefix.last == rendered

          segments = rendered.split("::")
          declared = eval_file_declared_names(node)
          lexical_nesting_for_prefix(lexical_prefix).each do |entry|
            candidate = "#{entry}::#{segments.first}"
            return candidate.split("::") + segments[1..] if declared.include?(candidate)
          end
          segments
        end

        # The file's declared-constant oracle {eval_constant_receiver_prefix}
        # consults: every class/module declaration plus constant write the file
        # contains, expanded to every enclosing prefix (declaring `S::A::B`
        # proves `S::A` exists). Memoized on the `Prism::Source` every node's
        # location shares — threading the set through the dozen eval-consuming
        # walks would dwarf the resolution it feeds, so the one re-parse this
        # needs happens once per file. The memo is a {TypingState} Memo, a
        # WeakKeyMap keyed on the source: the entry's lifetime is the parse's own
        # (the map holds the key weakly), the set is a pure function of the
        # source's text, and a worker parsing the same text gets its own source
        # and its own set. Not run-scoped: an entry holds no run's tables.
        DECLARED_NAMES = TypingState.memo(
          :scope_index_declared_names,
          audit: "scope index declared names",
          reason: "a WeakKeyMap keyed on the Prism::Source; the frozen set is a pure function of the source's text"
        )
        private_constant :DECLARED_NAMES

        def eval_file_declared_names(node)
          source = node.location.send(:source)
          return scan_declared_names(source) if MemoAudit.enabled? && MemoAudit.suspended?

          table = TypingState.current.weak_key_map(DECLARED_NAMES)
          stored = table[source]
          if stored.nil?
            return table[source] = MemoAudit.key_audit("scope index declared names") { scan_declared_names(source) }
          end

          MemoAudit.check("scope index declared names", stored, source.source.bytesize) { scan_declared_names(source) }
        end

        def scan_declared_names(source)
          names = Set.new
          collect_declared_constant_names(Prism.parse(source.source).value, [], names)
          names.freeze
        end

        # The walk behind {eval_file_declared_names}: every qualified constant
        # name a declaration introduces, `class`/`module`/`class <<` bodies and
        # `Const = …` writes alike. Deliberately NOT {ScopeIndexer#collect_class_decls} —
        # that walk resolves eval receivers through {eval_receiver_prefix},
        # which consults this oracle and would reenter it mid-build; this one
        # never asks the question it feeds. `def` bodies cannot contain constant
        # declarations (a `class`/`X =` inside one is a SyntaxError), so they
        # are skipped outright. Under an unnameable cref (`class <<`, an
        # anonymous factory block) bare and `self::` declarations name nothing —
        # the same refusal the discovery walks make — while explicit-base paths
        # still re-anchor lexically.
        def collect_declared_constant_names(node, qualified_prefix, names, unnameable_cref: false)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            return collect_declared_class_decl(node, qualified_prefix, names, unnameable_cref)
          when Prism::SingletonClassNode
            collect_declared_constant_names(node.expression, qualified_prefix, names,
                                            unnameable_cref: unnameable_cref)
            return collect_declared_constant_names(node.body, qualified_prefix, names,
                                                   unnameable_cref: true)
          when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode,
               Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
            return collect_declared_bare_write(node, qualified_prefix, names, unnameable_cref)
          when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode,
               Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
            return collect_declared_path_write(node, qualified_prefix, names, unnameable_cref)
          when Prism::ConstantTargetNode
            add_declared_name(names, (qualified_prefix + [node.name.to_s]).join("::")) unless unnameable_cref
            return
          when Prism::DefNode
            return
          when Prism::CallNode
            return if collect_declared_anonymous_factory?(node, qualified_prefix, names,
                                                          unnameable_cref)
          end
          node.compact_child_nodes.each do |child|
            collect_declared_constant_names(child, qualified_prefix, names,
                                            unnameable_cref: unnameable_cref)
          end
        end

        # The `class`/`module` arm of {collect_declared_constant_names}: the
        # header's own qualified name plus the body under it.
        def collect_declared_class_decl(node, qualified_prefix, names, unnameable_cref)
          prefix = declared_constant_path_prefix(node.constant_path, qualified_prefix,
                                                 unnameable_cref)
          add_declared_name(names, prefix.join("::")) if prefix
          if node.is_a?(Prism::ClassNode)
            collect_declared_constant_names(node.superclass, qualified_prefix, names,
                                            unnameable_cref: unnameable_cref)
          end
          collect_declared_constant_names(node.body, prefix || qualified_prefix, names,
                                          unnameable_cref: unnameable_cref)
        end

        # The bare `CONST =` arm of {collect_declared_constant_names}: the write
        # lands on the enclosing cref, so an unnameable one declines the name.
        def collect_declared_bare_write(node, qualified_prefix, names, unnameable_cref)
          prefix = qualified_prefix + [node.name.to_s]
          add_declared_name(names, prefix.join("::")) unless unnameable_cref
          collect_rvalue_declared_names(node.value, prefix, qualified_prefix, names,
                                        unnameable_cref)
        end

        # The `Path::CONST =` arm of {collect_declared_constant_names}.
        def collect_declared_path_write(node, qualified_prefix, names, unnameable_cref)
          prefix = declared_constant_write_prefix(node.target, qualified_prefix,
                                                  unnameable_cref)
          add_declared_name(names, prefix.join("::")) if prefix
          collect_rvalue_declared_names(node.value, prefix || qualified_prefix,
                                        qualified_prefix, names, unnameable_cref)
        end

        # The unnamed-factory arm of {collect_declared_constant_names}: a
        # `Class.new`/`Module.new`/`Data.define`/`Struct.new` block's cref is the
        # anonymous class — declarations inside name nothing these tables carry.
        # (An eval-family block is NOT special here: `Module.nesting` does not
        # change, so `class Y` inside `X.class_eval` still declares under the
        # lexical prefix — the generic child walk covers it.)
        def collect_declared_anonymous_factory?(node, qualified_prefix, names, unnameable_cref)
          return false unless meta_new_constant_rvalue?(node) && node.block

          node.compact_child_nodes.each do |child|
            next if child.equal?(node.block)

            collect_declared_constant_names(child, qualified_prefix, names,
                                            unnameable_cref: unnameable_cref)
          end
          collect_declared_constant_names(node.block, qualified_prefix, names,
                                          unnameable_cref: true)
          true
        end

        # The rvalue half of {collect_declared_constant_names}'s write arm: a
        # `Const = <factory> do … end` block's cref is the new class, so the block
        # declares under the WRITTEN prefix; the call's other children and any
        # non-factory rvalue keep the enclosing context.
        def collect_rvalue_declared_names(value, written_prefix, qualified_prefix, names,
                                          unnameable_cref)
          if value.is_a?(Prism::CallNode) && meta_new_constant_rvalue?(value) && value.block
            value.compact_child_nodes.each do |child|
              next if child.equal?(value.block)

              collect_declared_constant_names(child, qualified_prefix, names,
                                              unnameable_cref: unnameable_cref)
            end
            collect_declared_constant_names(value.block, written_prefix, names,
                                            unnameable_cref: unnameable_cref)
          else
            collect_declared_constant_names(value, qualified_prefix, names,
                                            unnameable_cref: unnameable_cref)
          end
        end

        # The qualified prefix a `class`/`module` header declares: a `::`-rooted
        # path re-anchors at the top level; a bare or `self::` path under an
        # unnameable cref names nothing; every explicit base re-anchors
        # lexically — the same split {declaration_prefix} gives the discovery
        # walks.
        def declared_constant_path_prefix(path, qualified_prefix, unnameable_cref)
          return Source::ConstantPath.qualified_name_or_nil(path)&.split("::") if Source::ConstantPath.rooted?(path)
          return nil if unnameable_cref &&
                        (path.is_a?(Prism::ConstantReadNode) || self_anchored_tail(path))

          Source::ConstantPath.declaration_prefix(qualified_prefix, path)
        end

        # The qualified name a `Path::CONST =` write declares — the write walk's
        # own convention: `::`-rooted and `self::`-anchored paths resolve first,
        # every other base files AS WRITTEN (`S2::C = 2` inside `class S` keys
        # `S2::C`, matching {ScopeIndexer#constant_path_write_key}'s as-written fallback
        # rather than the header rule's lexical re-anchor).
        def declared_constant_write_prefix(path, qualified_prefix, unnameable_cref)
          return Source::ConstantPath.qualified_name_or_nil(path)&.split("::") if Source::ConstantPath.rooted?(path)

          if (tail = self_anchored_tail(path))
            return nil if unnameable_cref

            return qualified_prefix + tail
          end
          Source::ConstantPath.qualified_name_or_nil(path)&.split("::")
        end

        # Every enclosing prefix of a declared name joins the oracle — a file
        # that declares `S::A::B` necessarily has `S` and `S::A` to declare it
        # under, so `A::B.class_eval` inside `class S` resolves `S::A::B`.
        def add_declared_name(names, qualified_name)
          segments = qualified_name.split("::")
          segments.each_index { |i| names << segments.first(i + 1).join("::") }
        end

        # The constant segments under a `self::`-anchored path — `self::A::B` → `["A", "B"]` —
        # or nil for every other base (`::`-rooted, constant, or dynamic).
        def self_anchored_tail(node)
          return nil unless node.is_a?(Prism::ConstantPathNode)

          segments = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            segments.unshift(current.name.to_s)
            current = current.parent
          end
          current.is_a?(Prism::SelfNode) ? segments : nil
        end

        # `Object`'s constants ARE the top-level constants — every discovery table keys them
        # bare, the same collapse {ScopeIndexer#self_write_name} applies — so a `self::`-anchored path
        # rooted at `Object` drops the segment rather than filing under a name nothing else
        # produces.
        def collapse_object_owner(prefix)
          prefix.first == OBJECT_OWNER ? prefix[1..] : prefix
        end

        # Whether an eval-family call's block rebinds `self` to the receiver spelled in source — false
        # for the bare and `self`-receiver forms, whose block keeps the ENCLOSING self (including the
        # singleton class inside `class << self`).
        def eval_named_receiver?(node)
          !(node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        end

        EMPTY_NESTING = [].freeze

        # The empty qualified prefix. Distinct from {EMPTY_NESTING} only in what it MEANS: the two are handed
        # to different parameters.
        EMPTY_PREFIX = [].freeze

        # The four recognised class-creating rvalue shapes at constant-write position — the same set
        # {#meta_new_block_body} recognises, so the cross-file table and the per-file block-as-method walk agree on what
        # counts as a declaration.
        def meta_new_constant_rvalue?(rvalue)
          class_new_call?(rvalue) || module_new_call?(rvalue) ||
            data_define_call?(rvalue) || struct_new_call?(rvalue)
        end

        # Whether a `class` / `module` header still names its declaration when it sits below an
        # unnameable singleton cref. A BARE header (`class D`) lands on the singleton's own
        # namespace — `#<singleton>::D` names nothing — and so does a `self::`-anchored or
        # dynamic base. Every other path — `::T`, `C::D`, `Foo::Bar` — resolves its base
        # lexically and stays nameable under the same approximation
        # {Source::ConstantPath.declaration_prefix} uses everywhere else.
        def decl_nameable_under_cref?(node)
          path = node.constant_path
          !path.is_a?(Prism::ConstantReadNode) &&
            !Source::ConstantPath.qualified_name_or_nil(path).nil?
        end

        # Whether a class/module header's body walks under the unnameable-cref marker: the
        # header opens `#<singleton>::Name` when the enclosing cref is unnameable and the
        # header itself names nothing reachable — a bare `D`, or a `self::` path no
        # rebound self covers. An EMPTY `self_decl` is the decline form (a `self::`
        # header under a self nothing names); a non-empty one re-anchors the body at a
        # real cref even below an unnameable enclosure.
        def unnameable_decl?(node, self_decl, singleton_cref)
          return true if self_decl && self_decl.empty?
          return false if self_decl&.any?

          singleton_cref && !decl_nameable_under_cref?(node)
        end

        # The context a `class`/`module` header gives its body: `[self_decl, child_prefix,
        # child_cref]` — the `self::`-anchored prefix when the header rides a rebound
        # self (nil otherwise), the body's qualified prefix, and the unnameable-cref
        # marker. nil when the header renders no prefix, which a parsed header cannot
        # but keeps every caller total.
        def decl_body_context(node, qualified_prefix, self_base, singleton_cref)
          self_decl = self_anchored_decl_prefix(node.constant_path, self_base)
          child_prefix = self_decl ||
                         Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
          return nil unless child_prefix

          [self_decl, child_prefix, unnameable_decl?(node, self_decl, singleton_cref)]
        end

        # The qualified prefix a `self::`-anchored declaration or write target names when
        # `self_base` names the REBOUND self — a `def_owner` override, a mixin `current_class`,
        # or a meta-new class prefix. nil `self_base` means `self` is the lexical class — the
        # lenient render of {Source::ConstantPath.declaration_prefix} already resolves it — and
        # `[]` marks a self no name exists for (an anonymous or singleton block), where the
        # path stays unnameable. nil return: not a `self::` path, or no override applies.
        def self_anchored_decl_prefix(path, self_base)
          return nil unless self_base && (tail = self_anchored_tail(path))
          return [] if self_base.empty?

          self_base + tail
        end

        # Whether a meta-new constant write's TARGET still names its class below an unnameable
        # singleton cref — the path-write twin of {#decl_nameable_under_cref?}. `::K`, `C::K`,
        # `Foo::F` resolve their base lexically; a bare `K =` / `K ||=` lands on the singleton's
        # own constant table, and a `self::` or dynamic base names nothing reachable — unless
        # `self_base` names a rebound self (`K = Class.new { self::X = … }` writes `K::X`).
        def meta_new_path_target_nameable?(node, self_base = nil)
          target =
            case node
            when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode then node.target
            else return false
            end
          return self_base.any? if self_base && self_anchored_tail(target)

          !Source::ConstantPath.qualified_name_or_nil(target).nil?
        end

        # Recognises `Data.define(*Symbol)` and `Data.define(*Symbol) do ... end` at constant-write rvalue position. The
        # receiver MUST be the bare `Data` constant (or `::Data`); other receivers (a local variable, a method call
        # return) are rejected because their identity is not statically known. Issue #2968 — a splatted member list
        # (`Data.define(*FIELDS)`) still creates the class; {ScopeIndexer#meta_members_open?} marks its members unknown.
        def data_define_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.name == :define
          return false unless meta_constant_receiver?(node.receiver, :Data)

          args = node.arguments&.arguments || []
          args.all? { |arg| meta_member_argument?(arg) }
        end

        # Recognises `Struct.new(*Symbol)` and `Struct.new(*Symbol, keyword_init: <expr>)` at constant-write rvalue
        # position. A trailing `KeywordHashNode` (the `keyword_init: ...` form) is accepted but does not contribute to
        # member discovery; every other argument MUST be a `Prism::SymbolNode`. At least one Symbol member is required —
        # `Struct.new()` is a degenerate form callers don't typically use.
        #
        # Issue #2968 — a leading String (`Struct.new("Named", :a)`, the class `Struct::Named`) and a splatted member
        # list (`Struct.new(*FIELDS)`) create the class just the same. {ScopeIndexer#meta_member_positionals} drops the
        # String; {ScopeIndexer#meta_members_open?} marks a splatted list's members unknown.
        def struct_new_call?(node)
          return false unless meta_call_with_name?(node, :Struct, :new)

          args = node.arguments&.arguments || []
          positional = struct_new_positionals(args)
          return false if positional.nil? || positional.empty?

          positional = positional.drop(1) if positional.first.is_a?(Prism::StringNode)
          positional.all? { |arg| meta_member_argument?(arg) }
        end

        def meta_member_argument?(arg)
          arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::SplatNode)
        end

        # Recognises `Module.new` and `Module.new(&block)` / `Module.new do ... end` at constant-write rvalue position.
        # The block body is the anonymous module's `module_eval` body; defs inside it bind methods on the named constant
        # (`Const = Module.new do ...; def foo; ...; end; end`). Arguments are NOT inspected because `Module.new`
        # accepts no positionals — Ruby raises ArgumentError if any are passed — so a malformed call falls through the
        # walker without affecting analysis.
        def module_new_call?(node)
          meta_call_with_name?(node, :Module, :new)
        end

        # Recognises `Class.new`, `Class.new(super_class)`, and the block form `Class.new { ... }`. Like
        # `module_new_call?`, the block body is walked as the anonymous class's body. The optional `super_class`
        # positional is accepted but does NOT route through `ancestor` discovery in this slice — the synthesised class
        # still answers method lookups via its own body's defs, mirroring how `Struct.new` / `Data.define` are handled.
        def class_new_call?(node)
          meta_call_with_name?(node, :Class, :new)
        end

        def meta_call_with_name?(node, receiver_name, method_name)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.name == method_name

          meta_constant_receiver?(node.receiver, receiver_name)
        end

        def struct_new_positionals(args)
          args.last.is_a?(Prism::KeywordHashNode) ? args[0..-2] : args
        end

        def meta_constant_receiver?(node, expected_name)
          case node
          when Prism::ConstantReadNode
            node.name == expected_name
          when Prism::ConstantPathNode
            node.parent.nil? && node.name == expected_name
          end
        end

        private_class_method :unwrap_or_guard, :freeze_tail?, :meta_constant_write_name, :scan_declared_names,
                             :collect_declared_constant_names, :collect_declared_class_decl,
                             :collect_declared_bare_write, :collect_declared_path_write,
                             :collect_declared_anonymous_factory?, :collect_rvalue_declared_names,
                             :declared_constant_path_prefix, :declared_constant_write_prefix, :add_declared_name,
                             :meta_member_argument?, :meta_constant_receiver?
      end
    end
  end
end
