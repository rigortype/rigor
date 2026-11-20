# frozen_string_literal: true

require_relative "../../type"
require_relative "../external_ancestor_resolution"
require_relative "../method_dispatcher"

module Rigor
  module Inference
    module CallLadder
      # The `top_level_def` rung of the call ladder (ADR-116 WD12): an implicit-self call of a name the project defines
      # as a top-level `def`, answered by re-typing that `def`'s body, where the call's own `self` does not answer the
      # name itself. `ExpressionTyper` asks it in a call's ladder, behind the literal-`send` rung. {ExpressionTyper} is
      # not required here: it requires this file, and `Scope` is loaded before either.
      #
      # {.try_call} is the rung, asked with the call's site and the walking typer, and the module's one entry: only the
      # ladder's entries ask it, so it has no second entry. Every other function is private to the module.
      #
      # The module holds no state. It reads the scope as `typer.scope` and calls back three methods of the typer:
      # `positional_correspondence` and `infer_user_method_return`, which re-type the body, and
      # `resolve_user_def_through_ancestors`, which the instance-side veto asks. `CallLadder::PORT` lists them. A
      # function that only reads the scope takes it as a parameter and never sees the typer.
      module TopLevelDef
        module_function

        # v0.0.3 A — implicit-self calls prefer a same-named top-level `def` over RBS dispatch. Without this, a
        # helper like `def select(...)` defined inside an `RSpec.describe ... do ... end` block mis-routes
        # through `Enumerable#select` / `Object#select` and the caller observes `Array[Elem]` instead of the
        # helper's actual return type. The check fires only for `node.receiver.nil?` (true implicit self), so
        # explicit-receiver dispatch is unaffected.
        #
        # Issue #316 — the lookup goes through the confidence-gated `Scope#bindable_top_level_def_for`, not the
        # raw table: inside a block whose `self` is unmodelled, a top-level `def` from ANOTHER file is not
        # evidence about which method the call reaches, so the bind is declined and the call widens.
        #
        # Issue #618 — the binding is a fallback for names the enclosing `self` does NOT answer, not a
        # first-choice tier. A top-level `def` is a private method on `Object`, the last link of every MRO, so
        # whenever the call's own `self` carries the name the class wins at runtime and the top-level body is
        # never reached. Binding regardless of `self_type` inverted that: a top-level `def text` typed the
        # member read inside `class Line < Struct.new(:text); def shout = text.upcase; end` as the def's `nil`
        # and fired `undefined method 'upcase' for nil` on correct code. The candidate is still looked up
        # first — that lookup is a hash probe and owns the ADR-46 cross-file dependency edge — and
        # {.self_type_answers?} then vetoes the bind for a name the enclosing class answers itself.
        #
        # Issue #963 item 2 — {.plugin_member_answers?} is the second veto, for the members no source the
        # engine walks can enumerate: a plugin's `dynamic_return` answer and the ADR-16 synthetic-method
        # index. They are members of `self` exactly as an `attr_reader` is, so a top-level `def` must not
        # bind ahead of them either.
        #
        # Issue #2861 — a bind the #316 gate declines answers `Dynamic[Top]`, never the RBS method of the same name: the
        # block's real `self` reaches either a same-named method of its own or the top-level `def`, which shadows
        # `Kernel#format` and every other `Object` / `Kernel` method on the way. Falling through typed
        # `format(r).bit_length` against `Kernel#format`'s `String` on code that runs the project's `def format`.
        #
        # The rung, asked with the call's site. The method name is the site's, not the call node's, and so are the
        # receiver, the argument types and the block type.
        def try_call(site, typer)
          node = site.call_node
          receiver = site.receiver
          arg_types = site.args
          method_name = site.method_name
          block_type = site.block_type
          return nil unless node.receiver.nil?

          local_def = typer.scope.bindable_top_level_def_for(method_name)
          return declined_top_level_def_answer(method_name, typer.scope) if local_def.nil?
          return nil if self_type_answers?(method_name, typer)
          return nil if plugin_member_answers?(node, receiver, method_name, typer.scope)

          local_inference = infer_top_level_user_method(local_def, receiver, node, arg_types, block_type, typer)
          return local_inference if local_inference

          # The local def matches by name but the inference was disqualified — the parameter shape is too
          # complex for the first-iteration binder (kwargs / optionals / rest), so the body could not be
          # re-typed. `Dynamic[Top]` is the safest answer: RBS dispatch would be wrong (the method is
          # user-defined and shadows whatever ancestor method the dispatch would find), and `Dynamic[Top]`
          # propagates correctly through downstream call chains without surfacing misleading false-positive
          # diagnostics.
          Type::Combinator.untyped
        end

        # Issue #2861 — the answer for an implicit-self call whose top-level `def` the #316 gate declined: nil (dispatch
        # as before) when the project defines no top-level `def` of the name, else `Dynamic[Top]`. The gate declines
        # only where `self_type` is nil, so no member of `self` ({.self_type_answers?}, {.plugin_member_answers?}) can
        # answer.
        def declined_top_level_def_answer(method_name, scope)
          return nil unless scope.opaque_block_self? && scope.self_type.nil?
          return nil if scope.top_level_def_for(method_name).nil?

          Type::Combinator.untyped
        end

        # v0.0.3 A — re-types a top-level (or DSL-block-nested) `def` discovered by `ScopeIndexer` under the
        # `TOP_LEVEL_DEF_KEY` sentinel. Mirrors the `infer_user_method_return` shape but uses the current
        # `scope.self_type` (or implicit `Object`) as the receiver carrier so the body's own self is
        # consistent with the call site's. Returns nil when the parameter shape disqualifies the def, when the
        # body is empty, or when the inference raises.
        def infer_top_level_user_method(def_node, receiver, call_node, arg_types, block_type, typer)
          arg_types, positionals_unknown = typer.positional_correspondence(call_node, arg_types)
          typer.infer_user_method_return(def_node, receiver, arg_types, yield_type: block_type,
                                                                        positionals_unknown: positionals_unknown)
        rescue StandardError
          nil
        end

        # Issue #618 — whether the call's enclosing `self` already answers `method_name`. Only a `self` whose
        # class is KNOWN participates: at genuine top level, and inside a block whose `self` is unmodelled,
        # `scope.self_type` is nil, the predicate is false, and the historical top-level binding stands — that
        # is #316's / #319's territory and this veto stays out of it.
        #
        # The ADR-48 member carriers answer from their own map first: a `StructInstance` / `DataInstance`
        # `self` carries the member set the body reads through, and an anonymous `Struct.new(...)` value has no
        # class name to look anything else up under.
        def self_type_answers?(method_name, typer)
          case (self_type = typer.scope.self_type)
          when Type::Singleton then singleton_self_answers?(self_type.class_name, method_name, typer.scope)
          when Type::Nominal then instance_self_answers?(self_type.class_name, method_name, typer)
          when Type::StructInstance, Type::DataInstance
            self_type.members.key?(method_name.to_sym) || instance_self_answers?(self_type.class_name, method_name,
                                                                                 typer)
          else false
          end
        end

        # Issue #963 item 2 — the plugin arm of the veto: whether a plugin answers `method_name` on the call's
        # own `self`. Asked of `MethodDispatcher.plugin_member_answers?`, which puts the question to the same
        # two tiers dispatch would consult (the gated `dynamic_return` walk and the ADR-16 synthetic-method
        # index), so the veto carries no plugin knowledge of its own.
        #
        # The confidence gate is #618's, unchanged and re-stated here rather than inherited: only a `self`
        # whose class is KNOWN participates. At genuine top level, and inside a block whose `self` is
        # unmodelled, `scope.self_type` is nil, `receiver` is the synthetic `Object` / `Dynamic[Top]` stand-in
        # that {ExpressionTyper#call_receiver_type_for} substitutes, and asking a plugin about THAT receiver would be
        # asking about a `self` the engine has not modelled — #316's / #319's territory, which this stays out of.
        def plugin_member_answers?(node, receiver, method_name, scope)
          return false if scope.self_type.nil?

          MethodDispatcher.plugin_member_answers?(
            call_node: node, scope: scope, receiver_type: receiver, method_name: method_name
          )
        end

        # The instance side of {.self_type_answers?}: the discovered methods (`def`, `attr_*`,
        # `define_method`, `alias`) of the class or any project ancestor, its `Struct.new` / `Data.define`
        # member accessors, a `def` reached through its project ancestors (superclass chain and included
        # modules), and an RBS method declared on an owner that PRECEDES `::Object` in the MRO.
        #
        # Issue #633 — the discovery arm walks ancestors because inheritance does not distinguish how a
        # method got there: a superclass `attr_accessor :stext` and an included module's `attr_reader` bind
        # ahead of a top-level `def stext` exactly as an inherited `def` does, and only the latter had a walk.
        #
        # The RBS arm's cut-off is `::Object`, not the own class. A top-level `def` IS a private `Object`
        # instance method, the last link of every MRO, so any declared owner that comes before `::Object`
        # wins at runtime — `Exception#message` for a `StandardError` subclass, `Array#first`,
        # `Comparable#clamp`. What the cut-off keeps out is the tier v0.0.3 A exists for and #316 / #319
        # refined: a name owned by `Object` or `Kernel` themselves (`inspect`, `format`) is at or after the
        # top-level `def`'s own rung, so the historical binding still stands there.
        def instance_self_answers?(class_name, method_name, typer)
          return false if class_name.nil?
          return true if typer.scope.discovered_method_through_ancestors?(class_name, method_name, :instance)
          return true if meta_member?(class_name, method_name, typer.scope)
          return true if typer.resolve_user_def_through_ancestors(class_name, method_name)
          return true if rbs_ancestor_answers?(class_name, method_name, typer.scope)

          # Issue #2968 — a class on the chain defines methods under names no table holds (`attr_accessor(*FLAGS)`, a
          # splatted `Struct.new(*FIELDS)`), so the name may be one of them, ahead of the top-level `def`.
          return true if Scope::DiscoveryIndex.open_names_on_chain?(typer.scope, class_name, :instance)

          # Issue #2994 — a class on the chain mixes in a module no table names (`include(*MODS)`, `include helper`),
          # so the name may be that module's, ahead of the top-level `def`.
          Scope::DiscoveryIndex.unnamed_mixin_on_chain?(typer.scope, class_name)
        end

        # The RBS arm of {.instance_self_answers?}. A project class is usually absent from the RBS
        # environment, so the declaration that decides the question is written about an ancestor the project
        # does not declare (`StandardError`, `Array`, `Comparable`) — each is asked on its own terms, and
        # each of them is itself before `::Object` in the reader's MRO by construction.
        #
        # Issue #527 slice 0 — the walk itself lives in {ExternalAncestorResolution}, which reports WHICH
        # declaration answered because the dispatch side needs to dispatch there. This tier only needs to
        # know that one did, so it reads the presence of an answer. Dependency recording stays ON: this
        # arm genuinely read the ancestor's declaration to decide the binding.
        def rbs_ancestor_answers?(class_name, method_name, scope)
          !ExternalAncestorResolution.resolve(class_name, method_name, :instance, scope: scope).nil?
        end

        # The singleton side: a class-body `self` is `Singleton[Foo]`, where an implicit-self call reaches
        # `Foo`'s own class methods before `Object`'s private top-level `def`.
        #
        # Issue #633 — both discovery arms follow the superclass chain, because a subclass inherits its
        # parent's class methods; `Scope` narrows the singleton walk to superclasses for the same reason
        # (an `include`d module's `def self.x` is not callable on the includer).
        def singleton_self_answers?(class_name, method_name, scope)
          return false if class_name.nil?
          return true if scope.discovered_method_through_ancestors?(class_name, method_name, :singleton)
          return true unless scope.singleton_def_through_ancestors(class_name, method_name).first.nil?

          declared = ExternalAncestorResolution.method_definition(class_name, method_name, :singleton, scope: scope)
          return true if ExternalAncestorResolution.declared_on_class?(declared, class_name)

          # Issue #2994 — a class object on the chain that a module no table names may extend through a hook (the
          # `:include_hook` open mark of a class with `include(*MODS)`), a class that `extend(*EMODS)`s, or an extended
          # module whose own module set is unknown, may answer any name ahead of the top-level `def`.
          Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods).unnamed_mixin?
        end

        # A `Struct.new(:a, :b)` / `Data.define(:a, :b)` member accessor. The layouts are a discovery table of
        # their own, separate from `discovered_methods`, so the accessor names they imply have to be asked for
        # explicitly. Only the reader name is tested: a writer is unreachable as an implicit-self call, since
        # bare `a = v` is a local assignment.
        def meta_member?(class_name, method_name, scope)
          layout = scope.struct_member_layout(class_name)
          members = layout ? layout[:members] : scope.data_member_layout(class_name)
          !members.nil? && members.include?(method_name.to_sym)
        end

        private_class_method :declined_top_level_def_answer, :infer_top_level_user_method, :self_type_answers?,
                             :plugin_member_answers?, :instance_self_answers?, :rbs_ancestor_answers?,
                             :singleton_self_answers?, :meta_member?
      end
    end
  end
end
