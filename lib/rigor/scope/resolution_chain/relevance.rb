# frozen_string_literal: true

module Rigor
  class Scope
    class ResolutionChain
      # ADR-119 WD2 — per-name relevance, the narrowing of an unsettled chain (#1591). A {Mark} says a node's mixin
      # edges have no known order; the chain still answers a question about ONE method name when the module the
      # mark names cannot answer that name, because with no fork every entry reached the chain by a single route,
      # so a module of unknown presence or position adds or removes only its own closure's entries and moves no
      # other entry's first occurrence. A closure that cannot answer the name therefore cannot move its first
      # definer. {ResolutionChain#settle} asks it under `unknown_for:`; nothing else does.
      #
      # - A named entry `Q` (not `"*"`) is discharged for `n` when every entry of `Q`'s own instance chain (its
      #   closure) is clean: (i) a project entry, or an external one RBS knows whose declaration lacks `n`
      #   (the test `SourceArity#external_mixin_lacks_method?` applies); (ii) no project entry carries the dynamic
      #   mark, lists `"*"` on the instance side or the mark's, or records `method_missing`; (iii) no project
      #   entry records `n` in `discovered_methods` (either kind) or in `discovered_method_visibilities`.
      # - A multi-file mark names no entry: it is discharged when at most one of the node's edges' closures is
      #   not clean. A mark that is both listed and multi-file must pass both rules.
      # - An ambiguous spelling (`:arity` only: several project modules a compact-header collision left as the
      #   spelling's meaning, #986) is discharged when every one of them is clean; any candidate that fails fails it.
      # - `"*"` and a truncated closure are never discharged.
      #
      # The verdict and the edges it read are memoised per `[mark, name]` in the flavor's bucket and the edges are
      # replayed on every call while a dependency recording is active (ADR-46): per tested project entry its class
      # edge and the negative method edge on `Owner#name`, per tested external the negative class edge on the last
      # segment of its spelling, so a new file declaring the module re-checks the consumer.
      module Relevance
        WILDCARD = "*"

        # The singleton hooks Ruby calls while a module enters (or is asked to enter) another's ancestry. A module
        # that defines one can add methods to the includer, extender or prepender with nothing the tables record
        # on the module (`def self.included(base) = base.attr_reader(:foo)`), so no closure holding one can be
        # said not to answer a name.
        HOOKS = %i[included extended prepended inherited append_features extend_object prepend_features].freeze
        TOPLEVEL_HOOK_EDGES = HOOKS.map { |hook| [:toplevel, hook.to_s].freeze }.freeze

        module_function

        def discharged?(scope, chain, mark, name)
          name = name.to_sym
          memo = ResolutionChain.relevance_memo(scope, chain.flavor)
          verdict, edges = memo[[mark, name]] ||= compute(scope, chain.flavor, mark, name)
          replay(scope, edges) if Analysis::DependencyRecorder.active?
          verdict
        end

        def compute(scope, flavor, mark, name)
          context = Context.new(scope, flavor, mark, name)
          verdict = !mark.listed.include?(WILDCARD) && listed_discharged?(context) && multi_file_discharged?(context)
          [verdict, context.edges.uniq.freeze].freeze
        end

        def listed_discharged?(context)
          mark = context.mark
          mark.listed.all? { |raw| context.closure_clean?(raw) }
        end

        def multi_file_discharged?(context)
          mark = context.mark
          return true unless mark.multi_file

          edges = context.edge_names
          edges.count { |raw| !context.closure_clean?(raw) } <= 1
        end

        def replay(scope, edges)
          edges.each do |kind, value|
            case kind
            when :class then ResolutionChain.record_class(scope, value)
            when :method then Analysis::DependencyRecorder.read_missing(:method, value)
            when :external then Analysis::DependencyRecorder.read_missing(:class, value)
            when :toplevel then Analysis::DependencyRecorder.read_missing(:toplevel, value)
            end
          end
        end

        # True only for an ancestor the chain holds as external that RBS knows and whose declaration lacks `name`
        # (`SourceArity#external_mixin_lacks_method?`), or, where RBS knows none of its candidates, that is a
        # {.bare_declared_module?}; an unknown one, or one that has it, may answer.
        def external_lacks?(scope, candidates, name)
          known = candidates.find { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: scope) }
          return bare_declared_module?(scope, candidates) if known.nil?

          Rigor::Reflection.instance_method_definition(known, name, scope: scope).nil?
        rescue StandardError
          false
        end

        # ADR-119 WD2's declared-module category (#1612): a module the project declares that the chain holds as
        # external, because nothing makes it a project entry (`Scope#known_user_class?`: no method, `def` or
        # mixin row on either side), defines no name, so it lacks every name — when nothing the tables cannot
        # see can define one on it or on its includer. Every candidate of the spelling the project declares must
        # be such a module, and at least one must be declared (an undeclared spelling is assumed absent, as the
        # chain's own name resolution assumes). A declared candidate passes when, from the tables alone:
        #
        # - it is declared with `module` and its envelope bucket holds nothing else: no name a call in its body
        #   mentions (`delegate :foo`, a concern's `included do my_macro :foo end`), no dynamic, refinement or
        #   object-extension mark;
        # - it records no `extend` (so no `ActiveSupport::Concern`, whose `included do`/`class_methods do`
        #   blocks run on the includer, and no module whose instance `included` becomes its hook), no
        #   unpositioned mixin (no `"*"`), and no visibility row;
        # - the project has no {.foreign_hook?}: a hook written outside its owner's body
        #   (`def Q.included(base) = base.attr_reader(:foo)`) is recorded against no module, so any one disables
        #   the category for every module.
        #
        # Accepted remainder: a hook `def` nested in a method or block body is recorded by no table, and a
        # receiverless macro call naming nothing (`acts_as_x`) records nothing, as it records nothing on a
        # project entry either.
        def bare_declared_module?(scope, candidates)
          discovery = scope.discovery
          declared = candidates.select do |candidate|
            discovery.discovered_class_sources.key?(candidate) || discovery.discovered_classes.key?(candidate)
          end
          return false if declared.empty? || foreign_hook?(scope)

          memo = ResolutionChain.relevance_memo(scope, :methods)
          declared.all? { |candidate| memo.fetch([:bare, candidate]) { memo[[:bare, candidate]] = bare?(scope, candidate) } }
        end

        # The ADR-46 edges a {.bare_declared_module?} verdict read, where a candidate is declared: every declaring
        # file of each candidate, and the top-level hook names a new file could define (`def Q.included` at the top
        # level is the `<toplevel>#included` def). A hook `def` a new edit writes inside another module's body
        # files no edge this read can name, so a warm run can miss that one.
        def declared_module_edges(scope, candidates)
          sources = scope.discovery.discovered_class_sources
          return EMPTY_NAMES unless candidates.any? { |candidate| sources.key?(candidate) }

          candidates.map { |candidate| [:class, candidate] } + TOPLEVEL_HOOK_EDGES
        end

        # Files the {.declared_module_edges} of `candidates` while a recording is active.
        def record_declared_module(scope, candidates)
          replay(scope, declared_module_edges(scope, candidates)) if Analysis::DependencyRecorder.active?
        end

        def bare?(scope, name)
          discovery = scope.discovery
          return false if scope.known_user_class?(name)

          envelopes = discovery.discovered_parameter_envelopes[name]
          return false unless envelopes&.size == 1 && envelopes.key?(DiscoveryIndex::ENVELOPE_MODULE_MARK)

          !discovery.discovered_extends.key?(name) && !discovery.unpositioned_mixins.key?(name) &&
            !discovery.discovered_method_visibilities.key?(name)
        end

        # Whether some hook `def` in the project is not its owner's own: a top-level one (`def Q.included` at the
        # top level), one its owner records on no matching side (`def Q.included` written in `module X` is the
        # walk's `X#included` def node and no `X` method), or one written twice for the same owner and side, so
        # one of the two may be another module's. Read from `discovered_deferred_ranges`, whose def rows name
        # every `def` outside a method or block body, and memoised per discovery index.
        def foreign_hook?(scope)
          memo = ResolutionChain.relevance_memo(scope, :methods)
          memo.fetch(:foreign_hook) { memo[:foreign_hook] = scan_foreign_hooks(scope.discovery) }
        end

        def scan_foreign_hooks(discovery)
          seen = {}
          discovery.discovered_deferred_ranges.each_value do |rows|
            rows.each do |(_start, _finish, name, kind, owner)|
              next unless HOOKS.include?(name)
              return true if owner.nil? || seen[[owner, name, kind]]

              seen[[owner, name, kind]] = true
              recorded = discovery.discovered_methods[owner]&.[](name)
              return true unless recorded == kind || recorded == DiscoveryIndex::METHOD_KIND_BOTH
            end
          end
          false
        end
        private_class_method :bare?, :scan_foreign_hooks

        # One verdict's working state: the scope, the resolver, and the edges the tests read.
        class Context
          attr_reader :mark, :edges

          def initialize(scope, flavor, mark, name)
            @scope = scope
            @flavor = flavor
            @mark = mark
            @name = name
            @resolver = ResolutionChain.resolver_for(scope, flavor)
            @edges = []
          end

          # The raw names of the node's own edges on the side the mark covers.
          def edge_names
            discovery = @scope.discovery
            table = @mark.kind == :extend ? discovery.discovered_extends : discovery.discovered_includes
            table[@mark.node] || EMPTY_NAMES
          end

          # Whether the closure of the module `raw` names from the marked node cannot answer the name.
          def closure_clean?(raw)
            resolved = @resolver.resolve(@mark.node, raw)
            case resolved
            when String then project_closure_clean?(resolved)
            when Array then resolved.all? { |name| project_closure_clean?(name) }
            else external_clean?(@resolver.candidates(@mark.node, raw), raw)
            end
          end

          private

          def project_closure_clean?(module_name)
            chain = ResolutionChain.for(@scope, module_name, :instance, @flavor)
            return false if chain.truncated?

            chain.entries.all? do |entry|
              entry.external? ? external_clean?(entry.candidates, entry.raw) : project_clean?(entry)
            end
          end

          def project_clean?(entry)
            owner = entry.name
            @edges << [:class, owner] << [:method, "#{owner}##{@name}"]
            return false if Scope::DiscoveryIndex.rewritten_surface?(@scope.parameter_envelopes_of(owner))
            return false if wildcard_listed?(owner)
            return false if @scope.discovered_method?(owner, :method_missing, :instance)
            return false if HOOKS.any? { |hook| @scope.discovered_method?(owner, hook, :singleton) }

            !records_name?(owner)
          end

          def wildcard_listed?(owner)
            sides = @scope.discovery.unpositioned_mixins[owner]
            return false if sides.nil?

            [:include, @mark.kind].uniq.any? { |side| sides[side]&.include?(WILDCARD) }
          end

          def records_name?(owner)
            @scope.discovered_method?(owner, @name, :instance) || @scope.discovered_method?(owner, @name, :singleton) ||
              !@scope.discovered_method_visibility(owner, @name).nil?
          end

          # An ancestor the project does not declare: only a module RBS knows, whose declaration lacks the name,
          # is evidence it does not define it (`SourceArity#external_mixin_lacks_method?`).
          def external_clean?(candidates, raw)
            @edges << [:external, raw.to_s.split("::").last]
            @edges.concat(Relevance.declared_module_edges(@scope, candidates))
            Relevance.external_lacks?(@scope, candidates, @name)
          end
        end
        private_constant :Context

        EMPTY_NAMES = [].freeze
        private_constant :EMPTY_NAMES
      end
    end
  end
end
