# frozen_string_literal: true

# THROWAWAY INSTRUMENTATION — issue #345 spike. Not production code. Delete with the spike.
#
# Hook sites (all gated, all `require_relative`d from the file they instrument):
#   lib/rigor/reflection.rb            resolve_constant_type  -> record_reference
#   lib/rigor/inference/scope_indexer.rb  .index              -> record_file_declarations
#   lib/rigor/analysis/runner.rb       run_analysis           -> record_run_shape
#   lib/rigor/analysis/runner.rb       apply_discovery_result -> record_project_class_sources,
#                                                               record_structural_edges
#   lib/rigor/environment/rbs_loader.rb add_project_signatures / add_virtual_rbs -> record_rbs_decls
#
# Collects the substrate for a future `rigor unused` reachability report:
#
# 1. **Resolved constant references** — recorded at `Rigor::Reflection.resolve_constant_type`'s
#    choke point, as the fully-qualified name the lexical walk actually resolved TO (not the
#    name as written).
# 2. **Declared constants** — recorded per analyzed file from `Inference::ScopeIndexer.index`
#    (`build_declaration_artifacts`'s per-file `discovered_classes`, and the per-file
#    `in_source_constants` table), keyed by declaration source path. Cross-checked against the
#    project-wide `discovered_class_sources` table the runner adopts.
#
# Everything is gated on `RIGOR_UNUSED_PROBE=<output.json>`. With the variable unset every hook
# short-circuits on one frozen-false read and the run is unchanged.
module Rigor
  module UnusedProbe
    # Set once at load time so an unset run never touches ENV again.
    OUTPUT_PATH = ENV.fetch("RIGOR_UNUSED_PROBE", nil)
    ACTIVE = !(OUTPUT_PATH.nil? || OUTPUT_PATH.empty?)

    # The pid that owns the dump. A forked worker inherits ACTIVE but must NOT write (it would
    # clobber the parent's file), and anything it accumulated is lost — which is exactly why the
    # harness forces `--workers=0`. `record_run_shape` below stores the effective worker count so
    # the report can refuse to report on a pooled run instead of silently under-counting.
    OWNER_PID = Process.pid

    @references = Hash.new(0)
    @rbs_references = Hash.new(0)
    @rbs_reference_sources = {}
    @declared_classes = {}
    @declared_constants = {}
    @project_class_sources = {}
    @structural_edges = {}
    @analyzed_files = []
    @workers = nil
    @cache_enabled = nil
    @notes = []

    class << self
      def active? = ACTIVE

      # Hook 1 — `Reflection.resolve_constant_type` returned `candidate` as the resolved FQN.
      def record_reference(fqn)
        @references[fqn.to_s] += 1
      end

      # Hook 2 — one analyzed file's declarations, from `ScopeIndexer.index`.
      def record_file_declarations(source_path, classes, constants)
        path = source_path.to_s
        return if path.empty?

        classes.each_key { |name| (@declared_classes[name.to_s] ||= []) << path }
        constants.each_key { |name| (@declared_constants[name.to_s] ||= []) << path }
      end

      # Hook 5 — project-side RBS. `Reflection.resolve_constant_type` is the SOURCE-side lexical
      # resolver; a constant named only from a `.rbs` type annotation never passes through it, so
      # without this hook every class whose only consumer is a signature reads as unreferenced.
      # `decls` is the parsed declaration list of one project `sig/` file (or one ADR-93 inline
      # virtual RBS); every `RBS::TypeName` reachable from it counts as a reference, EXCEPT a
      # declaration's own name (`class Foo` in RBS is a declaration, not a use).
      def record_rbs_decls(decls, source)
        names = []
        Array(decls).each { |decl| walk_rbs(decl, names, 0) }
        names.uniq.each do |name|
          @rbs_references[name] += 1
          (@rbs_reference_sources[name] ||= []) << source.to_s
        end
      end

      # Declaration nodes whose OWN `@name` is a declaration site rather than a reference.
      SELF_NAMED_DECLS = %w[
        RBS::AST::Declarations::Class RBS::AST::Declarations::Module
        RBS::AST::Declarations::Interface RBS::AST::Declarations::TypeAlias
        RBS::AST::Declarations::Constant RBS::AST::Declarations::Global
      ].freeze

      # Generic reflective walk. RBS's AST has no single public "every type name in here" visitor
      # that is stable across the 3.x/4.x range the gemspec supports, so the probe reflects over
      # ivars of `RBS::`-namespaced objects. Depth-capped; throwaway-grade by design.
      def walk_rbs(obj, acc, depth)
        return if depth > 40

        case obj
        when ::RBS::TypeName then acc << obj.to_s.delete_prefix("::")
        when Array then obj.each { |o| walk_rbs(o, acc, depth + 1) }
        when Hash then obj.each do |k, v|
          walk_rbs(k, acc, depth + 1)
          walk_rbs(v, acc, depth + 1)
        end
        when Symbol, String, Numeric, true, false, nil then nil
        else walk_rbs_object(obj, acc, depth)
        end
      end

      def walk_rbs_object(obj, acc, depth)
        klass = obj.class.name.to_s
        return unless klass.start_with?("RBS::")

        skip_name = SELF_NAMED_DECLS.include?(klass)
        obj.instance_variables.each do |ivar|
          next if skip_name && ivar == :@name

          walk_rbs(obj.instance_variable_get(ivar), acc, depth + 1)
        end
      end

      # Hook 3 — the project-wide `discovered_class_sources` table (name => Set[path]) the runner
      # adopts from the cross-file discovery pre-pass. Kept separate from hook 2 so the report can
      # show whether the per-file hook missed any file.
      def record_project_class_sources(table)
        table.each { |name, paths| (@project_class_sources[name.to_s] ||= []).concat(Array(paths).map(&:to_s)) }
      end

      # Hook 3b — MEASURED GAP (fixture3): `class Sub < Base` never reaches
      # `resolve_constant_type`, so a base class used only as a superclass reads as unreferenced
      # (`Rigor::CLI::Command`, `Rigor::Cache::RbsCacheProducer`). The names here are recorded AS
      # WRITTEN, not resolved; the report resolves them lexically against the declared set.
      # `includes` is carried for symmetry even though `include Foo` IS a normal call (and so
      # already resolves) — a plugin-rewritten include might not be.
      def record_structural_edges(superclasses, includes)
        superclasses.each { |sub, sup| (@structural_edges[sub.to_s] ||= []) << sup.to_s }
        includes.each do |klass, mods|
          Array(mods).each { |m| (@structural_edges[klass.to_s] ||= []) << m.to_s }
        end
      end

      # Hook 4 — run shape. `files` is the expanded analysis file set; `workers` the effective
      # worker count; `cache` whether a persistent cache store is attached.
      def record_run_shape(files:, workers:, cache:)
        @analyzed_files = Array(files).map(&:to_s)
        @workers = workers
        @cache_enabled = cache
      end

      def note(message)
        @notes << message.to_s
      end

      def dump!
        return unless ACTIVE
        return unless Process.pid == OWNER_PID

        require "json"
        payload = {
          "schema" => 1,
          "pid" => Process.pid,
          "cwd" => Dir.pwd,
          "workers" => @workers,
          "cache_enabled" => @cache_enabled,
          "notes" => @notes,
          "analyzed_files" => @analyzed_files,
          "references" => @references,
          "rbs_references" => @rbs_references,
          "rbs_reference_sources" => @rbs_reference_sources.transform_values(&:uniq),
          "declared_classes" => @declared_classes.transform_values(&:uniq),
          "declared_constants" => @declared_constants.transform_values(&:uniq),
          "project_class_sources" => @project_class_sources.transform_values(&:uniq),
          "structural_edges" => @structural_edges.transform_values(&:uniq)
        }
        File.write(OUTPUT_PATH, JSON.pretty_generate(payload))
      end
    end

    at_exit { dump! } if ACTIVE
  end
end
