# frozen_string_literal: true

require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../scope"
require_relative "../reflection"
require_relative "../type"
require_relative "../inference/scope_indexer"
require_relative "../inference/rbs_type_translator"

module Rigor
  module SigGen
    # Core generator for `rigor sig-gen` (ADR-14 slice 1 — MVP).
    #
    # Walks every `.rb` file under the input paths, builds a
    # per-node scope index via {Rigor::Inference::ScopeIndexer},
    # finds every `Prism::DefNode` whose enclosing class is
    # nameable, types the body's last expression to derive an
    # inferred return, looks up the project's existing RBS
    # declaration (if any), and emits one {MethodCandidate} per
    # def.
    #
    # The MVP keeps the scope deliberately narrow:
    # - Only instance methods inside a `class` / `module` body
    #   are considered. Top-level / DSL-block / singleton defs
    #   are skipped (`sig.skipped.complex-shape`).
    # - Parameter signatures are hard-coded to `untyped` per
    #   ADR-14 § "Robustness principle compliance" clause 2;
    #   `--params=observed` arrives in slice 3.
    # - Optional / rest / keyword / block params disqualify the
    #   def (`sig.skipped.complex-shape`).
    # - A `Dynamic[top]` inferred return becomes
    #   `sig.skipped.untyped-return` — emitting `untyped` would
    #   obscure rather than help.
    # - Tighter-return detection compares the RBS-erased
    #   spellings only when the existing declared return
    #   strictly accepts the inferred one (acceptance check
    #   under the engine's current `:gradual` mode; ADR-14
    #   reserves the eventual `:strict` mode).
    class Generator # rubocop:disable Metrics/ClassLength
      # @param configuration [Rigor::Configuration]
      # @param paths [Array<String>] files / directories to scan.
      def initialize(configuration:, paths:)
        @configuration = configuration
        @paths = paths
      end

      # @return [Array<MethodCandidate>]
      def run
        environment = build_environment
        resolved = resolve_paths(@paths)
        resolved.flat_map { |path| analyse_file(path, environment) }
      end

      private

      def build_environment
        Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths
        )
      end

      def resolve_paths(args)
        args.flat_map do |arg|
          if File.directory?(arg)
            Dir.glob(File.join(arg, "**/*.rb"), sort: true)
          elsif File.file?(arg) && arg.end_with?(".rb")
            [arg]
          else
            []
          end
        end.uniq
      end

      def analyse_file(path, environment)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: @configuration.target_ruby)
        return [] if parse_result.errors.any?

        base_scope = Scope.empty(environment: environment)
        scope_index = Inference::ScopeIndexer.index(parse_result.value, default_scope: base_scope)

        defs = collect_instance_defs(parse_result.value)
        defs.map { |def_node, class_name| classify_def(path, def_node, class_name, scope_index) }
      end

      # Walks the AST collecting `(def_node, class_name)` pairs
      # for plain `def foo` methods inside a `class` / `module`
      # body. `def self.foo`, singleton-class defs, and top-
      # level defs are skipped — the MVP only emits instance
      # methods that the engine's body-typing path can reach
      # without extra scaffolding.
      def collect_instance_defs(root)
        out = []
        walk_defs(root, [], false, out)
        out
      end

      def walk_defs(node, prefix, in_singleton_class, out) # rubocop:disable Metrics/CyclomaticComplexity
        return unless node.is_a?(Prism::Node)

        case node
        when Prism::ClassNode, Prism::ModuleNode
          name = qualified_constant_path(node.constant_path)
          if name
            walk_defs(node.body, prefix + [name], false, out) if node.body
            return
          end
        when Prism::SingletonClassNode
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_defs(node.body, prefix, true, out)
            return
          end
        when Prism::DefNode
          collect_def_node(node, prefix, in_singleton_class, out)
          return
        end

        node.compact_child_nodes.each { |child| walk_defs(child, prefix, in_singleton_class, out) }
      end

      def collect_def_node(node, prefix, in_singleton_class, out)
        return if node.receiver.is_a?(Prism::SelfNode) || in_singleton_class
        return if prefix.empty?

        out << [node, prefix.join("::")]
      end

      def qualified_constant_path(constant_path)
        case constant_path
        when Prism::ConstantReadNode
          constant_path.name.to_s
        when Prism::ConstantPathNode
          parent = qualified_constant_path(constant_path.parent) if constant_path.parent
          name = constant_path.name&.to_s
          return nil if name.nil?

          parent ? "#{parent}::#{name}" : name
        end
      end

      def classify_def(path, def_node, class_name, scope_index)
        return skipped(path, def_node, class_name, :complex_shape) unless simple_parameter_shape?(def_node.parameters)

        inferred = infer_return_type(def_node, scope_index)
        return skipped(path, def_node, class_name, :untyped_return) if inferred.nil? || dynamic_top?(inferred)

        environment = scope_index[def_node]&.environment
        method_def = lookup_existing_method(class_name, def_node.name, environment, scope_index[def_node])

        if method_def.nil?
          new_method_candidate(path, def_node, class_name, inferred)
        else
          compare_against_declared(path, def_node, class_name, inferred, method_def)
        end
      end

      # Required positionals only; the MVP's body-typing path
      # gives well-defined returns for that shape. Optional /
      # rest / keyword / block parameters route through the
      # `sig.skipped.complex-shape` reason until slices 3+
      # widen the param policy.
      def simple_parameter_shape?(params)
        return true if params.nil?
        return false unless params.is_a?(Prism::ParametersNode)

        params.optionals.empty? &&
          params.rest.nil? &&
          params.keywords.empty? &&
          params.keyword_rest.nil? &&
          params.block.nil?
      end

      # Mirrors the `def.return-type-mismatch` rule's body-type
      # extraction: type the implicit-return expression under
      # the scope the indexer associated with the body. The
      # parameter bindings (typed `untyped` per the indexer's
      # default) come from `with_local` inside
      # `StatementEvaluator`; the result is the carrier the
      # body proves *given an untyped argument tuple*. This is
      # the MVP's clause-1-precision read.
      def infer_return_type(def_node, scope_index)
        body = def_node.body
        return nil if body.nil?

        last = body_last_expression(body)
        return nil if last.nil?

        inner_scope = scope_index[last] || scope_index[body] || scope_index[def_node]
        return nil if inner_scope.nil?

        inner_scope.type_of(last)
      rescue StandardError
        nil
      end

      def body_last_expression(body)
        case body
        when Prism::StatementsNode then body.body.last
        when Prism::BeginNode then body_last_expression(body.statements)
        else body
        end
      end

      def dynamic_top?(type)
        type.is_a?(Type::Dynamic) || (type.respond_to?(:top?) && type.top?.yes?)
      end

      def lookup_existing_method(class_name, method_name, environment, scope)
        return nil if environment.nil?

        Reflection.instance_method_definition(
          class_name,
          method_name,
          scope: scope,
          environment: environment
        )
      end

      def new_method_candidate(path, def_node, class_name, inferred)
        MethodCandidate.new(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: :instance,
          classification: Classification::NEW_METHOD,
          inferred_return: inferred,
          rbs: render_rbs_line(def_node, inferred)
        )
      end

      def compare_against_declared(path, def_node, class_name, inferred, method_def)
        declared = build_declared_return(method_def)
        declared_rbs = declared&.erase_to_rbs
        inferred_rbs = inferred.erase_to_rbs

        if declared.nil? || declared_rbs == inferred_rbs
          return equivalent(path, def_node, class_name, inferred, declared_rbs)
        end

        return equivalent(path, def_node, class_name, inferred, declared_rbs) unless tighter?(declared, inferred)

        MethodCandidate.new(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: :instance,
          classification: Classification::TIGHTER_RETURN,
          inferred_return: inferred,
          declared_return_rbs: declared_rbs,
          rbs: render_rbs_line(def_node, inferred)
        )
      end

      def build_declared_return(method_def)
        translated = method_def.method_types.filter_map { |mt| translate_method_type_return(mt) }
        return nil if translated.empty?

        translated.size == 1 ? translated.first : Type::Combinator.union(*translated)
      end

      def translate_method_type_return(method_type)
        Inference::RbsTypeTranslator.translate(
          method_type.type.return_type,
          self_type: nil, instance_type: nil, type_vars: {}
        )
      rescue StandardError
        nil
      end

      # ADR-14 § "What 'more precise' means". The MVP uses the
      # engine's gradual-mode acceptance — `:strict` is
      # reserved by `Inference::Acceptance` and lands in a
      # follow-up. The "different spelling" guard ensures we
      # never classify a same-string round-trip as tighter.
      def tighter?(declared, inferred)
        return false if inferred.is_a?(Type::Dynamic)

        forward = declared.accepts(inferred)
        return false unless forward.yes?

        backward = inferred.accepts(declared)
        !backward.yes?
      end

      def equivalent(path, def_node, class_name, inferred, declared_rbs)
        MethodCandidate.new(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: :instance,
          classification: Classification::EQUIVALENT,
          inferred_return: inferred,
          declared_return_rbs: declared_rbs
        )
      end

      def skipped(path, def_node, class_name, reason)
        MethodCandidate.new(
          path: path,
          class_name: class_name,
          method_name: def_node.name,
          kind: :instance,
          classification: Classification::SKIPPED,
          skip_reason: reason
        )
      end

      def render_rbs_line(def_node, inferred)
        params = def_node.parameters
        arity = params.is_a?(Prism::ParametersNode) ? params.requireds.size : 0
        param_list = Array.new(arity, "untyped").join(", ")
        head = arity.zero? ? "()" : "(#{param_list})"
        "def #{def_node.name}: #{head} -> #{inferred.erase_to_rbs}"
      end
    end
  end
end
