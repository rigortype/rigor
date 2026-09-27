# frozen_string_literal: true

require_relative "../../source/constant_path"

module Rigor
  module Inference
    module DeclarationWalk
      # What `self`, the cref and `Module.nesting` are at one node of a {DeclarationWalk} (ADR-116 WD5). The walk
      # derives each child's context from its parent's through the transitions below, so every collector reads
      # the same answer for the same node and none of them recomputes it.
      #
      # - `prefix` — the qualified-name segments of the innermost `class` / `module` a name reaches, which is
      #   what the tables key lexical facts under: `["Admin", "User"]` inside `module Admin; class User`, `[]`
      #   at the top level. It is not always the cref. Directly inside `class << self` the cref is the
      #   singleton class, which has no name, and `prefix` stays the enclosing class's while `singleton_cref`
      #   says so; below a bare header there (`class D` opens `#<Class:C>::D`, which no name spells) it is
      #   `[]`.
      # - `self_owner` — the rebound `self` a `self::` header, write target or eval receiver anchors on. nil
      #   while `self` is the lexical class; a prefix while a meta-new or eval-family block rebinds it; `[]`
      #   while it names nothing (a `class <<` body, an anonymous factory block, an eval receiver no name
      #   reaches).
      # - `singleton_cref` — whether the lexical cref is unnameable. `class <<` sets it, and a header that
      #   still names its class re-anchors it.
      # - `nesting` — `Module.nesting` as the ancestry tables record it (issue #682): a nameable
      #   `class`/`module` keyword pushes, a `self::` header pushes the prefix its rebound self gives it, and
      #   nothing else pushes. nil when the caller does not track it, or when it was lost below a header that
      #   renders no name ({#lost_header_body}); only a `self::` header below a rebound self grows it again.
      # - `scope` — the census scope a collector types an rvalue under, carrying the chain
      #   {ScopeIndexer.scope_entering_declaration} stamps at each header. nil when the caller has none.
      # - `source_path` — the path of the file being walked, which an anonymous class's synthetic name carries
      #   ({AnonymousMetaClass.name_for}). nil when the caller has none. Read it through
      #   {#anonymous_class_path}, which answers each variant of that rule.
      # - `class_body` — whether a `class` / `module` body, a meta-new write's body or an eval-family block's
      #   body encloses the node. A `class <<` body and a bare factory block do not set it. It exists for the
      #   `anonymous_class_path` variant {#anonymous_class_path} documents, and nothing else reads it.
      #
      # Nameability is derived, not stored: {#unnameable_self?} answers it from the fields above.
      #
      # `nesting` and the chain on `scope` are two fields because the walks that threaded them disagree. The
      # scope's chain is pushed at EVERY header, an unnameable one and the lenient render of a `self::` header
      # included (`class self::D` pushes `Outer::D`); the ancestry chain is not. A move keeps both answers
      # (ADR-116's variant rule); the scope's is wrong below `class <<` (#1520), and converging the two is
      # #1521's.
      #
      # The rules themselves stay in {ScopeIndexer} ({ScopeIndexer.decl_body_context},
      # {ScopeIndexer.meta_new_block_split}, {ScopeIndexer.eval_block_split}), where the walkers not yet ported
      # still call them; this class is the one place a ported collector reaches them from. That is why the
      # entry point is `rigor/inference/declaration_walk`, which loads `ScopeIndexer` and, through it, this file.
      class Context
        EMPTY_PREFIX = [].freeze

        attr_reader :prefix, :self_owner, :singleton_cref, :nesting, :scope, :source_path, :class_body

        # A file's top level: `self` is `main`, which the lexical-class convention (a nil `self_owner`)
        # already answers.
        def self.root(scope: nil, nesting: nil, source_path: nil)
          new(EMPTY_PREFIX, nil, false, nesting, scope, source_path, false)
        end

        def initialize(prefix, self_owner, singleton_cref, nesting, scope, source_path, class_body)
          @prefix = prefix
          @self_owner = self_owner
          @singleton_cref = singleton_cref
          @nesting = nesting
          @scope = scope
          @source_path = source_path
          @class_body = class_body
          freeze
        end

        # Whether a bare, `self` or `self::` reference here names nothing a table can key on: inside a
        # `class <<` body, under a `self` an eval or factory block left unnamed, or below an unnameable cref
        # that no rebound self re-anchors.
        def unnameable_self?
          ScopeIndexer.unnameable_eval_self?(false, self_owner, prefix, singleton_cref)
        end

        # The file path an anonymous class created at this node carries in its synthetic name, under the
        # variant of that rule the asking collector follows (see {DeclarationWalk::RULE_VARIANTS}):
        #
        # - `:whole_file` — the walk's rule: the path everywhere, as the evaluator, the dispatcher and the
        #   methods walker name the class.
        # - `:outside_class_bodies` — `walk_class_superclasses`' rule, kept so the superclass table stays
        #   byte-identical: nil once {#class_body} is set, so `Class.new(P) { }` inside `class C` is keyed
        #   `#<Class:L:C>` while the other tables name it `#<Class:path:L:C>` (#1521 item 11).
        def anonymous_class_path(variant)
          case variant
          when :whole_file then source_path
          when :outside_class_bodies then class_body ? nil : source_path
          else raise ArgumentError, "no anonymous_class_path variant #{variant.inspect}"
          end
        end

        # The context a `class` / `module` header gives its body, or nil when the header renders no prefix
        # (a parsed header always renders one; nil keeps the transition total). `self` is the class again,
        # so the rebound self resets.
        def declaration_body(node)
          self_decl, child_prefix, child_cref =
            ScopeIndexer.decl_body_context(node, prefix, self_owner, singleton_cref)
          return nil unless child_prefix

          Context.new(child_cref ? EMPTY_PREFIX : child_prefix, nil, child_cref,
                      declaration_nesting(node, self_decl, child_cref),
                      ScopeIndexer.scope_entering_declaration(scope, node.constant_path), source_path, true)
        end

        # The context of a `class << expr` body. `self` is the singleton class, which no `self::` path names,
        # and the cref is unnameable until a nameable header re-anchors it. The rung Ruby pushes names nothing,
        # so neither chain moves.
        def singleton_class_body
          Context.new(prefix, EMPTY_PREFIX, true, nesting, scope, source_path, class_body)
        end

        # The body of a `K = Class.new { … }`-shaped write: `self` is the class the write names (`[]` when it
        # names none). The cref and both chains stay lexical.
        def meta_new_body(owner)
          Context.new(prefix, owner, singleton_cref, nesting, scope, source_path, true)
        end

        # The body of an eval-family block: `self` is the receiver (`[]` when no name reaches it). The cref and
        # both chains stay lexical.
        def eval_body(owner)
          Context.new(prefix, owner, singleton_cref, nesting, scope, source_path, true)
        end

        # The body of a bare factory block under the walk's rule: `self` is an anonymous class no name reaches.
        # The cref and both chains stay lexical.
        def factory_body
          Context.new(prefix, EMPTY_PREFIX, singleton_cref, nesting, scope, source_path, class_body)
        end

        # The body of a `class` / `module` whose header renders no name (`class foo`, `module` followed by a
        # `def`: parse-error shapes), under the `:body_with_lost_nesting` variant of the `unrendered_header`
        # rule (see {DeclarationWalk::RULE_VARIANTS}). `self` is the class again; the chain is kept below an
        # unnameable cref and lost (nil) otherwise, because nothing can be pushed for a header with no name.
        def lost_header_body
          Context.new(prefix, nil, singleton_cref, singleton_cref ? nesting : nil, scope, source_path, true)
        end

        # The prefix the meta-new and eval-family splits resolve against, under the variant of the
        # `lexical_prefix` rule the asking collectors follow: `:prefix` is the walk's rule; `:nesting_head` is
        # `walk_def_nestings`' — the innermost `Module.nesting` entry split into segments, or `[]`. The two
        # differ below a compact header (`["Admin::Widget"]` against `["Admin", "Widget"]`, which resolve an
        # eval receiver through different chains) and below an unnameable cref (`[]` against the enclosing
        # entry) (#1521).
        def lexical_prefix(variant = :prefix)
          case variant
          when :prefix then prefix
          when :nesting_head then (head = nesting&.first) ? head.split("::") : EMPTY_PREFIX
          else raise UnknownVariant, "no lexical_prefix variant #{variant.inspect}"
          end
        end

        # `[enclosing_parts, body, body_self]` for a `K = Class.new { … }`-shaped write, or nil when its
        # rvalue is not the idiom ({ScopeIndexer.meta_new_block_split}).
        def meta_new_split(node, variant = :prefix)
          ScopeIndexer.meta_new_block_split(node, lexical_prefix(variant), self_owner, singleton_cref)
        end

        # `[enclosing_parts, body, eval_self]` for an eval-family call with a block, or nil
        # ({ScopeIndexer.eval_block_split}).
        def eval_split(node, variant = :prefix)
          ScopeIndexer.eval_block_split(node, lexical_prefix(variant), self_owner, singleton_cref)
        end

        private

        # A `self::` header pushes the prefix its rebound self gives it even below a lost chain, which is how
        # `walk_def_nestings` has always read `[joined, *nil]`; any other header keeps a lost or untracked
        # chain nil.
        def declaration_nesting(node, self_decl, child_cref)
          return nesting if child_cref
          return [self_decl.join("::"), *nesting].freeze if self_decl
          return nesting if nesting.nil?

          Source::ConstantPath.pushed_nesting(nesting, node.constant_path) || nesting
        end
      end
    end
  end
end
