# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../../scope"
require_relative "../../type"
require_relative "../../inference/object_mixins"
require_relative "../../inference/definer_resolution"
require_relative "rbs_receiver_surface"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — the receiver predicates and signature helpers that more than one rule reads: whether a type
      # names a concrete class ({.concrete_class_name}), whether a class's method surface can be enumerated
      # ({.unbounded_receiver_surface?}), how a method is looked up and its signature trusted
      # ({.lookup_method}, {.receiver_signature}, {.trustworthy_signature}), and what the project's own source,
      # `pre_eval:` patches and refinements say about a name.
      #
      # Every method is a module function and none holds state. A rule calls these as `ReceiverPredicates.x`; this
      # module calls no rule back.
      # rubocop:disable-next Metrics/ModuleLength
      module ReceiverPredicates
        module_function

        # Is a refinement of `call_node`'s method name into `class_name` (or an ancestor) in effect at the call?
        # Issue #1120 asks it for a method the class lacks. The two argument rules ask
        # {#refined_redefinition_in_effect?} instead (issue #1740). Typing the call from the refine body is #1664.
        # Issue #1752 — a class-object receiver (`kind` `:singleton`) is reached by a refinement of any class or module
        # on its lookup: `Class`, `Module`, `Object`, `Kernel`, `BasicObject`, or a module it extends. A refined
        # singleton class (`refine X.singleton_class`) names no constant target, so its rows are class-unknown, which
        # reach every receiver. Issue #1673 — the answer is derived from the file's in-effect refinements
        # ({Inference::InEffectRefinements}), the list the typer reads, with each `using` expanded through its
        # module's includes (issue #1671).
        #
        # ADR-121 WD7 — a module in effect whose refinements Rigor cannot read
        # ({Inference::InEffectRefinements.opaque_module?}: a gem's, one from outside the analysed paths, one with an
        # unreadable `refine`) may refine any class, a class object's included, so the call declines whatever its
        # receiver. Issue #1796.
        def refined_method_in_effect?(class_name, call_node, scope, kind, lexical_sites)
          return false if lexical_sites.nil?
          return true if opaque_refinement_in_effect?(call_node, scope, lexical_sites)

          modules = Inference::InEffectRefinements.refining_modules(scope, class_name, call_node.name, kind)
          !modules.nil? &&
            lexical_sites.refinements.refinement_active?(call_node.location.start_offset, modules,
                                                         scope.declared_refinements) do |name|
              Inference::InEffectRefinements.activated_modules(scope, name)
            end
        end

        # Issues #1663, #1740 — the decline `call.wrong-arity` and `call.argument-type-mismatch` ask once a report
        # would fire: a refinement that REDEFINES a method the class already has replaces the signature those rules
        # check against, but Ruby finds a method the receiver's class (or a nearer ancestor) defines before it
        # consults an ancestor's refinement (`refine Object do def center(a, b, c)` leaves `"x".center(1, 2, 3)` an
        # `ArgumentError`). It stands on its own rather than behind {#refined_method_in_effect?}, whose ancestor
        # reach declines `class Inc; def bar(a); include N; end` under `refine N do def bar(a, b, c)` (issue #1797).
        #
        # A call with nothing in effect is checked. Otherwise it reports only from positive knowledge: the list
        # carries no unknown marker and no opaque module, and {Inference::RefinedDispatch::OwnMethod} proves the
        # receiver's own definer answers first. Issue #1752 — a class-object receiver (`kind` `:singleton`) walks its
        # singleton levels: `Integer.sqrt(1, 2)` under `refine Object do def sqrt(a, b)` runs `Integer.sqrt` and raises.
        def refined_redefinition_in_effect?(class_name, call_node, scope, kind, lexical_sites)
          return false if lexical_sites.nil?

          list = refinement_list_at(call_node, scope, lexical_sites)
          return false if list.empty?
          return true if list.include?(Inference::InEffectRefinements::UNKNOWN)
          return true if opaque_refinement_in_effect?(call_node, scope, lexical_sites)

          !Inference::RefinedDispatch::OwnMethod.answers?(scope, class_name, call_node.name, list, kind: kind)
        end

        # The in-effect list at the call as the typer reads it: the lexical activations, each `using` expanded,
        # then the plugin-declared modules (#1667).
        def refinement_list_at(call_node, scope, lexical_sites)
          query = lexical_sites.refinements
          declared = scope.declared_refinements
          return Inference::InEffectRefinements::EMPTY if query.empty? && declared.empty?

          query.at(call_node.location.start_offset, declared) do |name|
            Inference::InEffectRefinements.activated_modules(scope, name)
          end
        end

        # ADR-121 WD7 — does the call's in-effect list (its lexical activations, each `using` expanded; a
        # plugin-declared module is the plugin's declaration and never opaque) hold an opaque module?
        def opaque_refinement_in_effect?(call_node, scope, lexical_sites)
          query = lexical_sites.refinements
          return false if query.empty?

          list = Inference::InEffectRefinements.lexical_list(scope, query, call_node.location.start_offset)
          Inference::InEffectRefinements.opaque_in?(scope, list)
        end

        # Issue #1697 — a module the project mixes into `Object` (a top-level `include M`, or `include M` in
        # `class Object`) gives every object its instance methods, and the RBS lookup above only saw core's
        # `Object`. A class object is an `Object` whatever class it is, so the singleton side always reaches
        # it; the instance side does when the receiver's class descends from `Object`. A mixed-in module
        # whose surface is unknown, or a `module_function` reached only privately, does not count here
        # ({Inference::ObjectMixins.may_define?}).
        def object_mixin_may_define?(receiver_type, class_name, method_name, scope)
          unless receiver_type.is_a?(Type::Singleton) || Inference::ObjectMixins.reaches_object?(scope, class_name)
            return false
          end

          Inference::ObjectMixins.may_define?(scope, method_name, receiver: :explicit)
        end

        # Issue #735 — "does the project define this method, on either side, somewhere in its own files".
        # Distinct from {#project_definition_site}, which answers the narrower question the ADR-17 MESSAGE
        # asks (instance-side only, because that is the monkey-patch shape whose `pre_eval:` advice applies).
        # The suppression needs both sides: `def self.available_search_types` in one file and its call in
        # another is the same "second file of my own class" shape as the instance case, and on redmine it is
        # the larger half — modules with class-method surfaces are how that codebase is organised.
        def project_defines_method?(scope, class_name, method_name, kind)
          if kind == :singleton
            # The singleton side has no ancestor walk to ask (#731); it answers for the receiver's own name.
            !scope.user_singleton_def_site_for(class_name, method_name).nil?
          else
            # Through the project's ancestry, not the receiver's name alone: a base class defining a helper
            # its subclasses call is ordinary Ruby, and a sidecar `sig/` that declares the SUBCLASS without
            # that helper was reporting it (`AbstractAdapter#url`, called from `FilesystemAdapter#target`).
            # The def-node walk is what has to answer here — `discovered_methods` deliberately withholds a
            # plain cross-file `def` (`ScopeIndexer#finalize_def_index`), which is exactly this shape.
            !scope.user_def_through_ancestors(class_name, method_name).first.nil?
          end
        end

        def module_mixin_receiver?(receiver_type, scope)
          return false unless receiver_type.is_a?(Type::Nominal)
          return false if scope.environment.nil?

          scope.environment.rbs_module?(receiver_type.class_name)
        end

        # Combined suppression probe for `undefined-method` /
        # `unresolved-toplevel`. Returns true when the method is
        # declared by any project-side contributor the dispatcher
        # already resolves: an in-source `def` / `define_method`
        # (`scope.discovered_method?`) OR an ADR-17 `pre_eval:`
        # monkey-patch (`Environment#project_patched_methods`).
        # Both paths sit at the same dispatcher precedence; the
        # check must hold them together so neither rule fires a
        # false positive.
        #
        # `call_node:` (issue #1708), when given, is the call asking: a private or protected `pre_eval:` patch
        # it may not reach does not count ({#patch_callable?}).
        def source_declared_method?(scope, class_name, method_name, kind, call_node: nil)
          return true if scope.discovered_method?(class_name, method_name, kind)

          project_patched_method?(scope, class_name, method_name, kind, call_node: call_node)
        end

        # Issue #723 — the same question as {#source_declared_method?}, asked through the project's own
        # ANCESTRY rather than the receiver's name alone. A class whose `sig/` declares it without its
        # project superclass typed `:admin_val` under `dump_type` and drew `undefined method 'admin_val'`
        # at the same column of the same run: the probe read a name-keyed table while the typer resolved
        # the call through the class graph.
        #
        # It is deliberately NOT folded into `source_declared_method?`, which every `call.*` rule consults
        # early on its hot path. The walk reads `Scope#superclass_of` / `#includes_of`, and those record an
        # ADR-46 file-level ancestry edge; running it for every call would have made `Widget.new` — a call
        # RBS answers, that never reaches a verdict — record an ancestry dependency on `Widget`'s
        # declaring file, coarsening incremental invalidation for the whole project. Asked HERE, one step
        # before the diagnostic is built, the edge is recorded exactly where the answer depended on it.
        def ancestry_declares_method?(scope, class_name, method_name, kind)
          scope.discovered_method_through_ancestors?(class_name, method_name, kind)
        end

        # ADR-17 § "Inference contract" — consults
        # `Environment#project_patched_methods` so a `def` declared
        # in a `pre_eval:` file suppresses the diagnostic at the
        # same dispatcher precedence the registry holds for type
        # inference (between plugins and dependency-source).
        # Returns false when the environment carries no registry
        # (legacy path) or the lookup misses.
        def project_patched_method?(scope, class_name, method_name, kind, call_node: nil)
          environment = scope.environment
          registry = environment&.project_patched_methods
          return false if registry.nil? || registry.empty?

          entry = registry.lookup(class_name: class_name.to_s, method_name: method_name.to_sym, kind: kind)
          !entry.nil? && patch_callable?(registry, entry, scope, call_node)
        end

        # Issue #1708 — {#project_patched_method?} asked through the receiver's ancestors: a `pre_eval:` patch on
        # `Object`, `Numeric` or `Enumerable` gives an `Integer` or `Array` the method. Asked only once the
        # receiver's RBS has come back without the method, so a nearer class's own declaration still decides arity
        # and argument types; {#source_declared_method?} stays exact for the rules that read it for those.
        #
        # `call_node:` as {#source_declared_method?} reads it.
        def project_patched_through_ancestors?(scope, class_name, method_name, kind, call_node: nil)
          environment = scope.environment
          registry = environment&.project_patched_methods
          return false if registry.nil? || registry.empty?

          entry = registry.lookup_through_ancestors(class_name: class_name.to_s, method_name: method_name.to_sym,
                                                    kind: kind, rbs_loader: environment.rbs_loader)
          !entry.nil? && patch_callable?(registry, entry, scope, call_node)
        end

        # Issue #1708 — whether `call_node` may reach the patch `entry`: Ruby raises NoMethodError for a private
        # patch called with an explicit receiver other than `self` (`1.kp` on `module Kernel; private def kp`), and
        # for a protected one called from outside its owner's instances. No call node, and a declined verdict (another
        # definer the call may reach, {Inference::ProjectPatchedMethods#callable?}), are the permissive answer.
        def patch_callable?(registry, entry, scope, call_node)
          return true if call_node.nil?

          receiver = call_node.receiver
          verdict = registry.callable?(entry, explicit: !receiver.nil? && !receiver.is_a?(Prism::SelfNode),
                                              self_type: scope.self_type, rbs_loader: scope.environment.rbs_loader)
          verdict != false
        end

        # The receiver shapes whose method surface cannot be enumerated at all, whatever the environment
        # declares: a generic metaclass value, and an instance-side mixin-module type — an instance of some
        # unknown class that includes the module, which may declare the name with any arity of its own
        # (#739's reasoning, applied to the signature rather than to the method's existence).
        #
        # Instance-side only, for #739's reason: `Singleton[M]` on a namespace module is a real, enumerable
        # surface, and `M.helper(1, 2, 3)` must keep firing.
        def unenumerable_receiver_shape?(receiver_type, class_name, scope)
          METACLASS_ARMS.include?(class_name) || module_mixin_receiver?(receiver_type, scope)
        end

        # Returns a qualified class name for the in-scope check.
        # Nominal / Singleton carry a single-class identity
        # directly. Constant projects to its value's class.
        # Tuple projects to "Array" and HashShape to "Hash" so
        # arity / dispatch checks against the underlying class
        # still apply. Dynamic / Top / Union / Bot do not name a
        # single class and return nil to skip the rule.
        def concrete_class_name(type)
          case type
          when Type::Nominal, Type::Singleton then type.class_name
          when Type::Tuple then "Array"
          when Type::HashShape then "Hash"
          when Type::Constant then constant_class_name(type.value)
          # A refinement IS its base class for method dispatch — its method
          # surface is the base's. Resolve to the base so the call rules
          # (undefined-method / wrong-arity / argument-type-mismatch) reason
          # about it instead of bailing. `Type::Refined` carries string-family
          # refinements (`lowercase-string`, …) over an explicit `.base`;
          # `Type::IntegerRange` carries the bounded-int refinements
          # (`non-negative-int`, `positive-int`, `Integer[1..5]`), every one an
          # Integer; `Type::Difference` (`A - B`) carries the non-empty /
          # non-zero refinements (`non-empty-string` = `String - ""`,
          # `non-empty-array` = `Array - []`, `non-zero-int` = `Integer - 0`)
          # — subtracting values never changes the method surface, so the
          # base (minuend) class dispatches.
          when Type::Refined, Type::Difference then concrete_class_name(type.base)
          when Type::IntegerRange then "Integer"
          when Type::FloatRange then "Float"
          end
        end

        CONSTANT_CLASSES = {
          Integer => "Integer", Float => "Float", String => "String",
          Symbol => "Symbol", Range => "Range",
          TrueClass => "TrueClass", FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_CLASSES

        # ADR-67 WD6b — true when this call's receiver is *rooted at* a pristine inferred-parameter local (the
        # call-site union seeded at method entry). Every negative in-body rule (`call.undefined-method`,
        # wrong-arity, argument-type-mismatch, possible-nil, visibility) declines on such a receiver: an open
        # call-site set makes the inferred type a *lower bound*, so a diagnostic against it is a false positive
        # by construction (the same reasoning that keeps ADR-67 WD1 non-negotiable at the parameter boundary,
        # carried into the body). No-op on a normal `check` run — `inferred_param?` is false unless the
        # `parameter_inference:` gate seeded the table.
        def inferred_param_receiver?(call_node, scope)
          inferred_param_rooted?(call_node.receiver, scope)
        end

        # ADR-67 WD6b — the argument-position analogue: true when `arg` is rooted at an inferred-parameter
        # local. The argument-type-mismatch rule declines on it for the same lower-bound reason. `scope` is the
        # call's, and the receiver and any earlier argument run before `arg` and may rebind what a conditional's
        # predicate in it reads (`m((c = false; 1), c ? param : "x")`), so a predicate there is never folded.
        def inferred_param_argument?(arg, scope)
          inferred_param_rooted?(arg, scope, fold: false)
        end

        # ADR-67 WD6b — see {CheckRules::InferredParamGuard} for the shared root-walk contract.
        def inferred_param_rooted?(node, scope, fold: true)
          InferredParamGuard.rooted?(node, scope, fold: fold)
        end

        def constant_class_name(value)
          CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
          nil
        end

        # ADR-26's own counterpart, not a use of it — issue #660 tracks whether this deserves a first-class
        # mechanism of its own rather than living here as a constant. `open_receivers:` (the manifest field,
        # below) only takes effect once a project LOADS the plugin that names it, but a gem overlay
        # (`data/gem_overlay/`, ADR-72) is auto-applied to every project that locks the gem WITHOUT opting
        # into a plugin — there is no manifest in that path for an `open_receivers:` entry to live on. This
        # is that path's counterpart: the class names a BUNDLED overlay declares knowing the declaration is
        # partial, protected independent of any plugin manifest.
        #
        # MEMBERSHIP ALONE is not enough, though: `unbounded_receiver_surface?` (below) also requires the
        # overlay directory that made the entry true to have actually LOADED this run — otherwise a project
        # that never locks the gem, and happens to own a class of the same name itself, would silently lose
        # `call.undefined-method` (and inherited-name `wrong-arity`) on that class, the exact regression this
        # gate exists to avoid (ADR-26 WD1: the protection is active exactly when the RBS it protects is).
        #
        # `ActiveSupport::Duration` is the first (and, as of #632, only) member: it forwards any method its
        # own class doesn't define to the wrapped numeric via `method_missing` (audited against
        # ActiveSupport 8.1.3.1's `lib/active_support/duration.rb` — see
        # `data/gem_overlay/activesupport/core_ext.rbs`'s `ActiveSupport::Duration` comment for the full
        # audit), so declaring even its reader surface makes it RBS-known — and, without this, every member
        # the declaration omits would become a false `call.undefined-method` for every project that locks
        # activesupport, the overwhelming majority of which never opt into the plugin at all.
        # `ActiveSupport::Concern` joined it in #534 item 7. `class_methods do … end` synthesizes a
        # `ClassMethods` constant and `append_features` / `prepend_features` are part of the real surface,
        # none of which the two-line declaration enumerates — and a concern module is the receiver of that
        # surface in every Rails app, so the same argument applies with the same force.
        GEM_OVERLAY_OPEN_RECEIVERS = Set["ActiveSupport::Duration", "ActiveSupport::Concern"].freeze
        private_constant :GEM_OVERLAY_OPEN_RECEIVERS

        # Issue #1456 — the `data/core_overlay/` twin of {GEM_OVERLAY_OPEN_RECEIVERS}. `OpenStruct` defines each field
        # as a per-instance singleton method and answers the rest through a private `method_missing` (ostruct 0.6), so
        # no signature can enumerate its surface. The only other declaration in the environment is json's add-on
        # reopening (`json_create` / `as_json` / `to_json`), which made the class read as fully declared and every
        # field access a `call.undefined-method`. `data/core_overlay/ostruct.rbs` declares that `method_missing`; since
        # #2792 that alone keeps `call.undefined-method` silent, but the rules below still need the class named. No load
        # gate is needed: the core overlay loads into every environment that has RBS at all, so the list is active
        # whenever the declaration it protects is. Both sides of the class are open, as with
        # {GEM_OVERLAY_OPEN_RECEIVERS}, and an inherited Object / Kernel signature stops deciding `call.wrong-arity`
        # and `call.argument-type-mismatch` ({#unauthoritative_inherited_signature?}): lost true positives,
        # accepted. The general rule — a class declared only by another library's partial reopening — is #1978, not
        # this list.
        CORE_OVERLAY_OPEN_RECEIVERS = Set["OpenStruct"].freeze
        private_constant :CORE_OVERLAY_OPEN_RECEIVERS

        # True when the receiver class responds beyond an enumerable
        # RBS method table, so proving a call "undefined" against it is
        # unsound: a plugin-declared open receiver, a Rigor-bundled-
        # overlay open receiver ({GEM_OVERLAY_OPEN_RECEIVERS}) whose
        # bundled directory this run actually loaded, a core-overlay
        # open receiver ({CORE_OVERLAY_OPEN_RECEIVERS}), or a
        # Rigor-synthesized stub type (see `RbsLoader#synthesized_type_names`),
        # or a project-only reopen of a Ruby library class whose own RBS
        # did not load ({#ruby_library_reopen?}).
        def unbounded_receiver_surface?(class_name, scope)
          bare_name = class_name.to_s.sub(/\A::/, "")
          open_receiver?(class_name, scope) || synthesized_stub_receiver?(class_name, scope) ||
            CORE_OVERLAY_OPEN_RECEIVERS.include?(bare_name) ||
            (GEM_OVERLAY_OPEN_RECEIVERS.include?(bare_name) && gem_overlay_loaded?(scope)) ||
            ruby_library_reopen?(class_name, scope)
        end

        # Issue #2174 — `class Matrix` reopened with one `#:`-annotated method, and no `matrix` signatures
        # loaded, gives Matrix a declaration holding only that method ({RbsLoader#ruby_library_reopen?}).
        # `Matrix.identity(2)` is correct Ruby, so the class's surface is treated as open: `call.undefined-method`
        # declines on it, and a signature it only inherits (`Object#initialize` for `Matrix.new(rows)`) stops
        # deciding arity and argument types. Methods the project's own declaration lists stay checked.
        def ruby_library_reopen?(class_name, scope)
          loader = scope.environment&.rbs_loader
          return false if loader.nil? || !loader.respond_to?(:ruby_library_reopen?)

          loader.ruby_library_reopen?(class_name)
        end

        # ADR-26 — whether a loaded plugin declares `class_name` "open" (manifest `open_receivers:`): it responds
        # beyond its RBS surface.
        def open_receiver?(class_name, scope)
          registry = scope.environment&.plugin_registry
          return false if registry.nil?

          registry.open_receiver?(class_name)
        end

        # Whether THIS run's RBS environment actually includes Rigor's OWN partial declaration of
        # ACTIVESUPPORT — {GEM_OVERLAY_OPEN_RECEIVERS} membership alone must not grant the exemption (see
        # that constant's comment), and both members of that list are `ActiveSupport` classes, so the gate
        # asks for the activesupport overlay specifically. Issue #2857 added a SECOND bundled overlay
        # (`addressable`, eligible under `:rbs_collection` coverage), and a collection project can load it
        # while the activesupport overlay stays unloaded — keying on "any `data/gem_overlay/` directory"
        # would then silence `ActiveSupport::Duration#bar`, the ADR-26 false negative this gate exists to
        # prevent.
        #
        # `RbsLoader#signature_paths` is the same list `Environment.for_project` builds from
        # `resolved_paths + plugin_sig_paths + gem_sig_paths + collection_paths + overlay_paths`, and
        # two of its members can carry the activesupport declaration:
        #
        # - `data/gem_overlay/activesupport/` itself — a member if and only if `gem_overlay_paths` picked
        #   it (the gem is locked, its coverage source admits the overlay — `:missing` for activesupport —
        #   and its plugin twin is NOT reachable, ADR-72). {RbsLoader.gem_overlay_sig_paths} rebuilds the
        #   exact Pathname `for_project` appended, so a plain `include?` is the test: no other signature
        #   source can occupy that path;
        # - the bundled activesupport plugin twin's own `sig/`, when a project wires it through
        #   `signature_paths:` instead of `plugins:`. Before #672 that route loaded BOTH halves and
        #   `Duration` collapsed outright, so nothing fired and nothing needed protecting; now the overlay
        #   stands down and the twin's declaration is the one that loads — with no manifest behind it, so
        #   `open_receiver?` above stays false and this is the only thing standing between a real
        #   `Duration` receiver and a false `call.undefined-method` on every member the declaration
        #   omits. {RbsLoader.gem_overlay_twin_signatures_loaded?} enumerates `GEM_OVERLAY_PLUGIN_IDS`'
        #   values, which today is only the activesupport twin; a second overlay twin would need the same
        #   per-gem keying this method now applies to the directory arm.
        #
        # When the PLUGIN itself is loaded the first arm goes false (the overlay stands down) and the
        # second goes true — its `sig/` rides in as a plugin signature path — but nothing here decides
        # that case: `open_receiver?`'s manifest-driven check short-circuits above it. The two answers
        # agree, which is the point; this predicate asks only whether the Rigor-authored activesupport
        # declaration is in the environment, never how the project asked for it.
        #
        # The two arms are asked in that order, over the WHOLE list each time, rather than interleaved
        # per path: the overlay arm is a Pathname comparison (plus the two `File.directory?` probes
        # {RbsLoader.gem_overlay_sig_paths} needs to rebuild the path) and the twin arm canonicalises
        # paths on the filesystem, so an overlay-only run pays the cheaper arm first.
        def gem_overlay_loaded?(scope)
          loader = scope.environment&.rbs_loader
          return false if loader.nil? || !loader.respond_to?(:signature_paths)

          paths = loader.signature_paths
          activesupport_overlay = Rigor::Environment::RbsLoader.gem_overlay_sig_paths(["activesupport"])
          paths.any? { |path| activesupport_overlay.include?(path) } ||
            Rigor::Environment::RbsLoader.gem_overlay_twin_signatures_loaded?(paths)
        end

        # Issue #653 — true when a plugin's `dynamic_return` supplied the return type for THIS call node
        # (recorded by `MethodDispatcher` on `Scope#plugin_typed_calls` during the typing pass, exactly the
        # way `Scope#void_origins` is recorded and consumed).
        #
        # Why the rule declines. The plugin tier sits ABOVE `RbsDispatch` in `MethodDispatcher#resolve`, so
        # a plugin answer means the RBS never dispatched the call: the type at the site is the plugin's.
        # Reading that same receiver's RBS afterwards to prove the call undefined puts the two subsystems in
        # direct contradiction on one line of one run — the plugin says `Rails.logger` is an
        # `ActiveSupport::BroadcastLogger`, the rule says `logger` does not exist. Under ADR-5 a
        # partially-declared receiver is not a closed world, and incompleteness is exactly what a plugin is
        # loaded to cover, so the plugin's answer is the honest one. Without this, adding a four-line
        # partial `sig/` for a class a plugin already covered turned every covered call site into an error
        # — writing more RBS made a project's diagnostics worse.
        #
        # Deliberately NOT scoped to "the RBS is silent about this method": the precedence recorded here is
        # the dispatcher's own, and the dispatcher does not consult the RBS before letting a plugin answer.
        # For THIS rule the two readings coincide anyway — a method the RBS declares is found by
        # `lookup_method` below and never reaches the diagnostic — so the broader statement costs no
        # diagnostic and keeps the contract stated in one direction. `docs/internal-spec/plugin.md` §
        # "Return-type and narrowing contributions" is where it binds.
        #
        # Unlike {#unbounded_receiver_surface?} this is per CALL SITE, not per receiver class: a plugin
        # answering `Rails.logger` exempts that call and nothing else, so `Rails.no_such_reader` on the same
        # receiver still fires.
        def plugin_typed_call?(call_node, scope)
          scope.plugin_typed_call?(call_node)
        end

        def synthesized_stub_receiver?(class_name, scope)
          loader = scope.environment&.rbs_loader
          return false if loader.nil? || !loader.respond_to?(:synthesized_type_names)

          loader.synthesized_type_names.include?(class_name.to_s.sub(/\A::/, ""))
        end

        # ADR-26 — the SIGNATURE half of the open-receiver policy. `call.undefined-method` already declines
        # on an unbounded surface: a plugin vouches that the class answers names its RBS cannot enumerate
        # (an `ActiveRecord::Relation` delegates every user-declared `scope` to its model). The rules that
        # read a RESOLVED SIGNATURE — wrong-arity and argument-type-mismatch — must decline on the same
        # ground, but only where the name resolved through an ANCESTOR rather than the open class itself.
        #
        # The failure it closes: `Issue.visible.open` is a declared scope taking `*args`, but `open` is also
        # `Kernel#open`, so resolution walks the Relation's ancestry, finds the IO opener and checks the
        # call against `(String, ...)` — `wrong number of arguments (given 0, expected 1..3)` on correct
        # code, plus `argument type mismatch: expected String, got false` on `open(false)`. The collision
        # set is every Object/Kernel name, so any project whose scope is called `open`, `select`, `test`,
        # `format`, `p`, `system`, … inherits the error the moment the first hop types. That is a wrong
        # signature applied to a method the receiver does not actually run — not a strict reading of a real
        # one — and it fires on code that works.
        #
        # A method the open class DECLARES stays checked: `Relation#limit` is in the plugin's own bundled
        # RBS, so `relation.limit` with no arguments still fires. The suppression is therefore bounded to
        # names the open class inherited, where the resolution was never authoritative to begin with.
        # The RBS method definition this call may be validated against, or nil when there is none worth
        # trusting: the lookup found nothing, it returned {#lookup_method}'s defensive `true` sentinel, or
        # the name is one an open receiver INHERITED rather than declared. Shared by the two rules that read
        # a resolved signature — `call.wrong-arity` and `call.argument-type-mismatch` — so they cannot drift
        # on which signatures are authoritative.
        def trustworthy_signature(receiver_type, class_name, call_node, scope)
          method_def = lookup_method(receiver_type, class_name, call_node.name, scope)
          return nil if method_def.nil? || method_def == true
          return nil if unauthoritative_inherited_signature?(class_name, method_def, scope)

          method_def
        end

        # Issue #2786 — {#trustworthy_signature} on the call's receiver as {CallFacts} types it, resolved once per
        # call node: `call.wrong-arity` and `call.argument-type-mismatch` both ask it with that receiver type and its
        # concrete class.
        def receiver_signature(facts)
          facts.receiver_signature do
            receiver_type = facts.receiver_type
            trustworthy_signature(receiver_type, concrete_class_name(receiver_type), facts.call_node, facts.scope)
          end
        end

        def unauthoritative_inherited_signature?(class_name, method_def, scope)
          return false unless unbounded_receiver_surface?(class_name, scope)
          return true unless method_def.respond_to?(:defined_in)

          defined_in = method_def.defined_in
          return true if defined_in.nil?

          strip_root(defined_in.to_s) != strip_root(class_name)
        end

        def strip_root(name) = name.to_s.sub(/\A::/, "")

        def definition_available?(receiver_type, class_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            !Rigor::Reflection.singleton_definition(class_name, scope: scope).nil?
          else
            !Rigor::Reflection.instance_definition(class_name, scope: scope).nil?
          end
        end

        def lookup_method(receiver_type, class_name, method_name, scope)
          if receiver_type.is_a?(Type::Singleton)
            Rigor::Reflection.singleton_method_definition(class_name, method_name, scope: scope)
          else
            Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
          end
        rescue StandardError
          # The Reflection facade catches loader exceptions and
          # returns nil. The wrapper here treats failures as
          # "method exists" so we do NOT emit a false positive
          # when our knowledge of the receiver class is
          # structurally incomplete (Reflection's own rescue
          # already returns nil; this catch is a defensive
          # double-net for any future call shape that might
          # raise).
          true
        end

        def nil_member?(member)
          (member.is_a?(Type::Constant) && member.value.nil?) ||
            (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
        end

        def method_present_anywhere?(member, method_name, scope)
          class_name = concrete_class_name(member)
          return true if class_name.nil? # Dynamic / Top / Bot — be permissive.
          return true if scope.discovered_method?(class_name, method_name, :instance)
          return true unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return true unless definition_available?(member, class_name, scope)
          return true if lookup_method(member, class_name, method_name, scope)
          return true if project_patched_through_ancestors?(scope, class_name, method_name, :instance)

          # Issue #723 — the arm's own RBS does not have it; its project ancestry still might. Late, for
          # the reason {#ancestry_declares_method?} carries: this is the probe that walks the class graph.
          return true if ancestry_declares_method?(scope, class_name, method_name, :instance)

          object_mixin_may_define?(member, class_name, method_name, scope)
        end

        # An arm that makes a sound "undefined on every arm" verdict impossible: a non-class surface
        # (Dynamic / Top / Bot), a singleton (slice 1 reasons about instance arms only), the generic
        # metaclass `Class` / `Module` (a value typed as one is *some* class/module object whose singleton
        # methods cannot be enumerated from the metaclass — e.g. `plugin_class : Class` really holds a
        # `Plugin` subclass with `.manifest`), an unbounded receiver (ADR-26 open class or a synthesized
        # stub), or a module mixin whose Object-inherited methods the per-arm lookup would miss.
        METACLASS_ARMS = %w[Class Module].to_set.freeze
        private_constant :METACLASS_ARMS

        # Whether `class_name` is the generic metaclass `Class` / `Module`; {UndefinedMethod} asks it rather than
        # reading {METACLASS_ARMS}, which stays private.
        def metaclass_arm?(class_name)
          METACLASS_ARMS.include?(class_name)
        end
      end
    end
  end
end
