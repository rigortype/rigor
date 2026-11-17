# frozen_string_literal: true

require_relative "../diagnostic"
require_relative "receiver_predicates"
require_relative "self_closedness_scanner"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `call.self-undefined-method` (ADR-24 slice 4): an implicit-self call inside a closed
      # class body that no method of the class, its project subclasses or its mixins can answer.
      #
      # The one entry point is {.diagnostics}, called by `CheckRules.diagnose`. It reads {ReceiverPredicates}
      # and {SelfClosednessScanner} and calls nothing else in `CheckRules`.
      module SelfUndefinedMethod
        module_function

        # ADR-24 slice 4 — `call.self-undefined-method`. Consumes the engine's
        # recorded unresolved implicit-self calls
        # ({Analysis::SelfCallResolutionRecorder}) and adds only the
        # closedness POLICY — it NEVER recomputes resolution (the reverted
        # attempt-1 mistake that produced 135 FPs). A miss reaches here only
        # because the engine's real resolution found the method nowhere.
        #
        # The v1 gate is deliberately the most conservative "confidently
        # closed" shape: a STANDALONE project class — no superclass and no
        # `include`/`prepend` (so its in-file method surface is complete) —
        # that is not a module / mixin contract, defines no `method_missing`,
        # has no dynamic `attr_*(*splat)` accessor, and is not an ADR-26 open
        # receiver. Widening to superclass / include chains is a later slice,
        # each behind the external corpus FP gate. Authored `:warning` but
        # mapped to `:off` in every shipped profile until that gate is green
        # (ADR-24 § "Slice 4"); a project opts in via `severity_overrides:`.
        def diagnostics(path, self_call_misses, root, scope_index)
          return [] if self_call_misses.empty?

          open_names = SelfClosednessScanner.new(root).open_class_names
          self_call_misses.filter_map do |miss|
            next if open_names.include?(miss.class_name)

            scope = scope_index[miss.node]
            next if scope.nil?
            next unless confidently_closed_self_class?(miss.class_name, scope)
            next if method_defined_on_known_subclass?(miss.class_name, miss.method_name, scope)

            build_self_undefined_method_diagnostic(path, miss)
          end
        end

        # ADR-24 slice 4 — subclass-aware gating (the abstract / template-method
        # base-class false positive the WD4 corpus eval surfaced). A base class
        # legitimately calls a method its subclasses implement
        # (`Mail::CommonField#decoded` calls `do_decode`, which
        # `Mail::UnstructuredField < CommonField` and its siblings define; the
        # same shape covers `Mail::Retriever#find` → POP3 / IMAP). When the
        # missed method is discovered on ANY known subclass of the self-class,
        # the call is a template-method hook, not a typo — suppress. Walks the
        # project subclass closure (the `discovered_superclasses` child→parent
        # map inverted, cycle-guarded). A pure narrowing — it only ever
        # suppresses a firing the closed-class gate would otherwise emit.
        def method_defined_on_known_subclass?(class_name, method_name, scope)
          supers = scope.discovered_superclasses
          seen = {}
          queue = direct_subclasses(class_name, supers)
          until queue.empty?
            subclass = queue.shift
            next if seen[subclass]

            seen[subclass] = true
            return true if method_known_on_class?(subclass, method_name, scope)

            queue.concat(direct_subclasses(subclass, supers))
          end
          false
        end

        # The directly-recorded subclasses of `class_name`. `discovered_superclasses`
        # keys the child fully-qualified (`Mail::POP3`) but records the parent
        # *as written* (`Retriever`), so a qualified miss class (`Mail::Retriever`)
        # is matched by resolving the parent name in the child's namespace.
        def direct_subclasses(class_name, discovered_superclasses)
          discovered_superclasses.filter_map { |child, parent| child if parent_matches?(child, parent, class_name) }
        end

        # Ruby constant lookup: a recorded parent `Retriever` on child
        # `Mail::POP3` resolves to `Mail::Retriever` (walk the child's namespace
        # prefixes, longest first), matched against the miss's fully-qualified
        # class name. Namespace-anchored, so it cannot match a same-named base in
        # an unrelated namespace.
        def parent_matches?(child, parent, class_name)
          parent_name = parent.to_s
          # Issue #722 residue 1 — a rooted parent (`< ::Base`) names the top level, so the namespace walk
          # below must not run for it. This peel is one of the two that predate
          # `Scope#ancestor_name_candidates` and resolve their own pair.
          return parent_name.delete_prefix("::") == class_name if parent_name.start_with?("::")
          return true if parent_name == class_name

          segments = child.to_s.split("::")[0...-1]
          until segments.empty?
            return true if "#{segments.join('::')}::#{parent_name}" == class_name

            segments.pop
          end
          false
        end

        # Whether `method_name` is defined on `class_name` in the project — a
        # plain `def` (the def-node table) or a dynamic definition
        # (`define_method` / `attr_*` / `alias`). `discovered_method?` alone
        # misses plain defs, which is exactly what the abstract hooks are.
        def method_known_on_class?(class_name, method_name, scope)
          !scope.user_def_for(class_name, method_name).nil? ||
            scope.discovered_method?(class_name, method_name, :instance)
        end

        # ADR-24 slice 4 — the universal bases. A recorded self-call miss tagged
        # with one of these means the engine fell back to the root self-type
        # because it could NOT resolve the real class (a class-body macro context
        # where self is the Class object, top-level `main`, `instance_eval`, an
        # FFI / `define_method` metaprogramming surface). Their instance method
        # set is never "project-known and complete" — every object also responds
        # to whatever the unresolved real class adds — so a miss there is a
        # resolution gap, not a typo. This is the dominant false-positive class
        # the WD4 corpus eval surfaced (protobuf 73 / tdiary 199 / pycall 10 /
        # … FFI + class-macro calls, 287 firings across the corpus); excluding
        # it is a pure narrowing.
        SELF_UNDEFINED_UNIVERSAL_BASES = %w[Object BasicObject Kernel].to_set.freeze
        private_constant :SELF_UNDEFINED_UNIVERSAL_BASES

        def confidently_closed_self_class?(class_name, scope)
          return false if SELF_UNDEFINED_UNIVERSAL_BASES.include?(class_name)
          return false if ReceiverPredicates.unbounded_receiver_surface?(class_name, scope)
          return false if scope.discovered_method?(class_name, :method_missing, :instance)
          # A superclass or mixin extends the surface beyond what this file
          # declares; the engine's ancestor walk may have hit an unresolvable
          # ancestor, so a miss is not provably a typo. Defer to a later slice.
          return false if scope.superclass_of(class_name)
          return false unless scope.includes_of(class_name).empty?

          true
        end

        def build_self_undefined_method_diagnostic(path, miss)
          Diagnostic.new(
            path: path,
            line: miss.line || 1,
            column: miss.column || 1,
            message: "implicit-self call to `#{miss.method_name}` resolves to no method on " \
                     "`#{miss.class_name}` (a standalone class with a complete, project-known " \
                     "method surface). Likely a typo or a missing `def`.",
            severity: :warning,
            rule: RULE_SELF_UNDEFINED_METHOD,
            source_family: :builtin,
            receiver_type: miss.class_name,
            method_name: miss.method_name
          )
        end

        private_class_method :method_defined_on_known_subclass?, :direct_subclasses, :parent_matches?,
                             :method_known_on_class?, :confidently_closed_self_class?,
                             :build_self_undefined_method_diagnostic
      end
    end
  end
end
