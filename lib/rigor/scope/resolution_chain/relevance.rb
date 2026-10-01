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
            end
          end
        end

        # True only for an ancestor that cannot define `name`: a module the project declares but that has no
        # `def` (a concern holding only `included do` blocks sits here, not as a project entry) when
        # {project_lacks?} holds, or one the project does not declare that RBS knows and whose declaration lacks
        # `name` (`SourceArity#external_mixin_lacks_method?`). An unknown one, or one that has it, may answer.
        # `edges` collects the recording edges {project_lacks?} reads; without it they are filed directly.
        def external_lacks?(scope, candidates, name, edges = nil)
          declared = candidates.find { |candidate| ResolutionChain.declared?(scope, candidate) }
          return bare_module_lacks?(scope, declared, name, edges) if declared

          known = candidates.find { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: scope) }
          return false if known.nil?

          Rigor::Reflection.instance_method_definition(known, name, scope: scope).nil?
        rescue StandardError
          false
        end

        # A declared module with no `def` is judged only when its body can hold no macro: one that extends,
        # includes, prepends or lists a mixin may run `included do my_macro :foo end` (or a helper's hook) that
        # defines on the includer with nothing the tables record, so it is never said to lack the name.
        def bare_module_lacks?(scope, owner, name, edges)
          local = edges || []
          verdict = if bare_module?(scope, owner)
                      project_lacks?(scope, owner, name, local)
                    else
                      local << [:class, owner]
                      false
                    end
          replay(scope, local) if edges.nil? && Analysis::DependencyRecorder.active?
          verdict
        end

        # No mixin table lists the module, and every file declaring it gives it a body of nested constant,
        # module and class definitions and literals only. A call in the body (`extend ActiveSupport::Concern`,
        # `included do my_macro :foo end`, `include`, `private`) is recorded in no table and may define the name
        # on the includer, so it ends the judgement; so does a file that cannot be read or does not show the module.
        def bare_module?(scope, owner)
          return false if [scope.discovered_extends, scope.discovered_includes,
                           scope.discovery.unpositioned_mixins].any? { |table| table.key?(owner) }

          memo = ResolutionChain.relevance_memo(scope, :methods)
          memo.fetch([:bare, owner]) do
            sites = ResolutionChain.declaring_files(scope, owner)
            memo[[:bare, owner]] = !sites.nil? && !sites.empty? && sites.all? { |site| bare_in_file?(site, owner) }
          end
        end

        def bare_in_file?(path, owner)
          found = false
          bare = true
          each_module_body(Prism.parse_file(path).value.statements, nil) do |name, body|
            next unless name == owner

            found = true
            bare &&= body.nil? || body.body.all? { |node| bare_statement?(node) }
          end
          found && bare
        rescue StandardError
          false
        end

        def each_module_body(statements, prefix, &)
          statements.body.each do |node|
            case node
            when Prism::ModuleNode, Prism::ClassNode
              name = [prefix, node.constant_path.full_name.delete_prefix("::")].compact.join("::")
              yield name, node.body
              each_module_body(node.body, name, &) if node.body.is_a?(Prism::StatementsNode)
            when Prism::StatementsNode then each_module_body(node, prefix, &)
            end
          end
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          nil
        end

        LITERALS = [Prism::IntegerNode, Prism::FloatNode, Prism::StringNode, Prism::SymbolNode, Prism::NilNode,
                    Prism::TrueNode, Prism::FalseNode].freeze
        private_constant :LITERALS

        def bare_statement?(node)
          case node
          when Prism::ModuleNode, Prism::ClassNode then true
          when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode then LITERALS.any? { |klass| node.value.is_a?(klass) }
          else LITERALS.any? { |klass| node.is_a?(klass) }
          end
        end

        # Whether the project module `owner` cannot answer `name`: no rewritten surface, no `"*"` mixin (on the
        # include side and on `kind`, or on either side without a `kind`), no `method_missing`, no singleton hook,
        # and no record of the name. Files `[:class, owner]` and the negative `[:method, "Owner#name"]` on `edges`.
        def project_lacks?(scope, owner, name, edges, kind = nil)
          edges << [:class, owner] << [:method, "#{owner}##{name}"]
          return false if Scope::DiscoveryIndex.rewritten_surface?(scope.parameter_envelopes_of(owner))
          return false if wildcard_listed?(scope, owner, kind)
          return false if scope.discovered_method?(owner, :method_missing, :instance)
          return false if HOOKS.any? { |hook| scope.discovered_method?(owner, hook, :singleton) }

          !records_name?(scope, owner, name)
        end

        def wildcard_listed?(scope, owner, kind)
          sides = scope.discovery.unpositioned_mixins[owner]
          return false if sides.nil?

          (kind ? [:include, kind].uniq : %i[include extend]).any? { |side| sides[side]&.include?(WILDCARD) }
        end

        def records_name?(scope, owner, name)
          scope.discovered_method?(owner, name, :instance) || scope.discovered_method?(owner, name, :singleton) ||
            !scope.discovered_method_visibility(owner, name).nil?
        end

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
            Relevance.project_lacks?(@scope, entry.name, @name, @edges, @mark.kind)
          end

          # An ancestor the project does not declare: only a module RBS knows, whose declaration lacks the name,
          # is evidence it does not define it (`SourceArity#external_mixin_lacks_method?`).
          def external_clean?(candidates, raw)
            @edges << [:external, raw.to_s.split("::").last]
            Relevance.external_lacks?(@scope, candidates, @name, @edges)
          end
        end
        private_constant :Context

        EMPTY_NAMES = [].freeze
        private_constant :EMPTY_NAMES
      end
    end
  end
end
