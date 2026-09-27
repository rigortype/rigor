# frozen_string_literal: true

require "bundler"
require "json"
require "open3"
require "prism"
require "rbconfig"

# #1507 — the declaration-fact witness. It runs a fixture in a child process under the Ruby running the suite (the
# Flake's locally, CI's on CI), with the bundle stripped, records what Ruby itself says about the modules the fixture
# declares, and compares that with the discovery tables Rigor builds for the same file. `violations` returns one line
# per disagreement; an empty list means the tables agree with Ruby.
#
# What Ruby is asked, per module the fixture opens or creates:
#
# - `Module.nesting` at every line the fixture runs. A `def` is a statement, so its line carries the nesting its body
#   is compiled under, `class << self` bodies included (a `:class` TracePoint does not report those);
# - its own instance methods by visibility, and its own singleton methods plus those its singleton mixins (`extend`)
#   give it, each with `Method#source_location`;
# - its ancestors, split into its own instance mixins and its own singleton mixins, and its superclass;
# - the class of each class variable's value, for the fixtures that call the method that assigns one.
#
# The relations:
#
# - A set-valued table must satisfy `certain ⊆ runtime ⊆ certain ∪ possible`. Rigor keeps no `possible` table yet, so
#   every entry reads as `certain` and the relation is equality, with one exception. A self-extend edge that Ruby
#   does not show, which is how the tables model a bare `module_function` (#526's deliberate over-approximation),
#   reads as `possible`, and so do the singleton names the extends fold derives from it.
# - A single-valued table must agree with Ruby wherever it answers. No entry is a decline, which is always allowed.
# - Def identity is compared through `source_location` lines.
# - A typed table must admit the class of the value Ruby holds.
#
# Ruby renders a module nested in an anonymous one as `#<Class:…>::Name`, which no constant path reaches. Rigor cannot
# name it, so it is left out of the runtime sets, and an anonymous entry is dropped from a runtime nesting before the
# chains are compared. A runtime method counts only when its `source_location` is in the fixture, so a reopened core
# class brings only the fixture's own methods.
module DeclarationWitness
  RELATIONS = %i[
    classes methods visibilities def_nodes singleton_def_nodes superclasses includes extends def_nestings class_cvars
  ].freeze

  # Runs in the child: `ruby -e RECORDER fixture.rb`, printing one JSON document.
  RECORDER = <<~'RUBY'
    require "json"

    path = File.expand_path(ARGV.fetch(0))
    name_of = ->(mod) { mod.name || mod.inspect }
    in_fixture = ->(location) { location && File.expand_path(location[0]) == path ? location[1] : nil }

    nestings = {}
    opened = []
    trace = TracePoint.new(:class, :line) do |tp|
      next unless File.expand_path(tp.path) == path

      if tp.event == :class
        opened << tp.self
      else
        nestings[tp.lineno] ||= tp.binding.eval("Module.nesting").map(&name_of)
      end
    end

    before = ObjectSpace.each_object(Module).to_a
    error = nil
    begin
      trace.enable { load path }
    rescue Exception => e
      error = "#{e.class}: #{e.message}"
    end
    modules = (opened + (ObjectSpace.each_object(Module).to_a - before)).uniq.reject(&:singleton_class?)

    record = modules.to_h do |mod|
      meta = mod.singleton_class
      superclass = mod.is_a?(Class) ? mod.superclass : nil
      stop = superclass ? superclass.singleton_class : Module
      singleton_mixins = meta.ancestors.drop(1).take_while { |a| a != stop && a != Class }
      singleton_names = (meta.instance_methods + meta.private_instance_methods).select do |n|
        [meta, *singleton_mixins].include?(meta.instance_method(n).owner)
      end
      instance_names = mod.instance_methods(false) + mod.private_instance_methods(false)
      chain = superclass ? mod.ancestors.take_while { |a| a != superclass } : mod.ancestors
      [name_of.(mod), {
        "superclass" => superclass && name_of.(superclass),
        "instance_mixins" => (chain - [mod]).map(&name_of),
        "singleton_mixins" => singleton_mixins.map(&name_of),
        "public" => mod.public_instance_methods(false).map(&:to_s),
        "private" => mod.private_instance_methods(false).map(&:to_s),
        "protected" => mod.protected_instance_methods(false).map(&:to_s),
        "instance_locations" => instance_names.to_h { |n| [n.to_s, in_fixture.(mod.instance_method(n).source_location)] },
        "singleton_locations" => singleton_names.to_h { |n| [n.to_s, in_fixture.(meta.instance_method(n).source_location)] },
        "class_variables" => mod.class_variables(false).to_h do |cv|
          [cv.to_s, mod.class_variable_get(cv).class.ancestors.map(&name_of)]
        end
      }]
    end

    puts JSON.generate("error" => error, "nestings" => nestings, "modules" => record)
  RUBY

  module_function

  # Every disagreement between Ruby and Rigor's tables for the fixture at `path`, restricted to `relations`.
  def violations(path, relations: RELATIONS)
    runtime = record(path)
    tables, root = rigor_tables(path)
    relations.flat_map { |relation| Relations.public_send(:"#{relation}_violations", runtime, tables, root) }
  end

  # What Ruby says about the fixture. A fixture that raises is a broken fixture, not a finding.
  def record(path)
    out, err, status = Bundler.with_unbundled_env { Open3.capture3(RbConfig.ruby, "-e", RECORDER, path) }
    raise "witness recorder failed for #{path}: #{err}" unless status.success?

    runtime = JSON.parse(out)
    raise "witness fixture #{path} raised #{runtime['error']}" if runtime["error"]

    runtime
  end

  # The discovery index `rigor check` analyses the fixture under: the project pre-pass over the one file, seeded
  # the way `Analysis::Runner#project_scope_seed_tables` seeds it, then the file's own `ScopeIndexer.index` merge.
  def rigor_tables(path)
    project = Rigor::Inference::ScopeIndexer.discovered_project_index_for_paths([path])
    index = project.fetch(:def_index)
    seed = {
      discovered_classes: project.fetch(:classes), discovered_def_nodes: index[:def_nodes],
      discovered_def_nestings: index[:def_nestings], discovered_singleton_def_nodes: index[:singleton_def_nodes],
      discovered_superclasses: index[:superclasses], discovered_header_nestings: index[:header_nestings],
      discovered_includes: index[:includes], discovered_prepends: index[:prepends], discovered_extends: index[:extends],
      discovered_method_visibilities: index[:method_visibilities], discovered_methods: index[:methods]
    }
    base = Rigor::Scope.empty(source_path: path)
    root = Prism.parse(File.read(path), filepath: path).value
    seeded = base.with_discovery(base.discovery.with(**seed))
    [Rigor::Inference::ScopeIndexer.index(root, default_scope: seeded).default.discovery, root]
  end
end

module DeclarationWitness
  # One method per relation, `<relation>_violations(runtime, tables, root)`, each returning its disagreement lines.
  # `runtime` is {DeclarationWitness.record}'s document and `tables` the discovery index Rigor built.
  module Relations
    module_function

    def nameable?(name)
      !name.include?("#<")
    end

    # Whether a name as the source wrote it reaches the runtime module named `runtime_name`.
    def written_matches?(written, runtime_name)
      bare = written.delete_prefix("::")
      runtime_name == bare || runtime_name.end_with?("::#{bare}")
    end

    def classes_violations(runtime, tables, _root)
      certain = tables.discovered_classes.keys
      defined = runtime["modules"].keys.select { |name| nameable?(name) }
      (certain - defined).map { |name| "classes: Rigor declares #{name}, which Ruby does not define" } +
        (defined - certain).map { |name| "classes: Ruby defines #{name}, which Rigor does not declare" }
    end

    def methods_violations(runtime, tables, _root)
      facts = method_facts(tables)
      possible = self_extend_possible(runtime, tables, facts)
      certain = facts - possible
      observed = runtime_method_facts(runtime)
      unrecorded = observed - certain - possible
      (certain - observed).map { |fact| "methods: Rigor records #{fact.join(' ')}, which Ruby does not define" } +
        unrecorded.map { |fact| "methods: Ruby defines #{fact.join(' ')}, which Rigor does not record" }
    end

    # `[owner, side, name]` for every entry of `discovered_methods`, a `:both` entry counting on each side.
    def method_facts(tables)
      tables.discovered_methods.flat_map do |owner, kinds|
        kinds.flat_map do |name, kind|
          sides = kind == Rigor::Scope::DiscoveryIndex::METHOD_KIND_BOTH ? %w[instance singleton] : [kind.to_s]
          sides.map { |side| [owner, side, name.to_s] }
        end
      end
    end

    # The owners whose self-extend edge Ruby does not show.
    def unconfirmed_self_extends(runtime, tables)
      tables.discovered_extends.select do |owner, targets|
        targets.include?(owner) && !runtime.dig("modules", owner, "singleton_mixins")&.include?(owner)
      end.keys
    end

    # The singleton-side facts an unconfirmed self-extend edge derives: `possible`, not `certain`.
    def self_extend_possible(runtime, tables, facts)
      owners = unconfirmed_self_extends(runtime, tables)
      facts.select { |owner, side, _| side == "instance" && owners.include?(owner) }
           .map { |owner, _, name| [owner, "singleton", name] }
    end

    def runtime_method_facts(runtime)
      runtime["modules"].select { |name, _| nameable?(name) }.flat_map do |owner, record|
        %w[instance singleton].flat_map do |side|
          record["#{side}_locations"].filter_map { |name, line| [owner, side, name] if line }
        end
      end
    end

    def visibilities_violations(runtime, tables, _root)
      tables.discovered_method_visibilities.flat_map do |owner, table|
        record = runtime.dig("modules", owner)
        next [] unless record

        table.filter_map do |name, visibility|
          actual = %w[public private protected].find { |v| record[v].include?(name.to_s) }
          next unless actual && actual != visibility.to_s

          "visibilities: Rigor records #{owner}##{name} as #{visibility}; Ruby makes it #{actual}"
        end
      end
    end

    def def_nodes_violations(runtime, tables, _root)
      def_identity(runtime, tables.discovered_def_nodes, "instance", "#")
    end

    # A singleton def the extends fold copied along an unconfirmed self-extend edge is `possible`: missing from Ruby
    # is allowed, a different def is not.
    def singleton_def_nodes_violations(runtime, tables, _root)
      def_identity(runtime, tables.discovered_singleton_def_nodes, "singleton", ".",
                   unconfirmed_self_extends(runtime, tables))
    end

    def def_identity(runtime, table, side, separator, possible_owners = [])
      table.flat_map do |owner, defs|
        next [] if owner == Rigor::Inference::ScopeIndexer::TOP_LEVEL_DEF_KEY

        defs.filter_map do |name, def_node|
          line = def_node.location.start_line
          actual = runtime.dig("modules", owner, "#{side}_locations", name.to_s)
          next if actual == line || (actual.nil? && possible_owners.include?(owner))

          where = actual ? "Ruby's is the def at line #{actual}" : "Ruby has no such def in the fixture"
          "#{side}_def_nodes: Rigor resolves #{owner}#{separator}#{name} to the def at line #{line}; #{where}"
        end
      end
    end

    def superclasses_violations(runtime, tables, _root)
      tables.discovered_superclasses.filter_map do |owner, written|
        actual = runtime.dig("modules", owner, "superclass")
        next if actual && written_matches?(written, actual)

        "superclasses: Rigor records #{owner} < #{written}; Ruby's superclass is #{actual || 'undefined'}"
      end
    end

    def includes_violations(runtime, tables, _root)
      mixin_violations(runtime, tables.discovered_includes, "instance_mixins", "includes")
    end

    # A self edge is how the tables model `module_function` as well as `extend self`, and Ruby shows only the
    # latter. Its effect is judged under `methods`, so it is left out on both sides here.
    def extends_violations(runtime, tables, _root)
      mixin_violations(runtime, tables.discovered_extends, "singleton_mixins", "extends", skip_self: true)
    end

    def mixin_violations(runtime, table, key, label, skip_self: false)
      owners = (table.keys + runtime["modules"].keys.select { |name| nameable?(name) }).uniq
      owners.flat_map do |owner|
        kept = ->(name) { nameable?(name) && !(skip_self && name == owner) }
        written = table.fetch(owner, []).select(&kept)
        shown = runtime.dig("modules", owner, key).to_a.select(&kept)
        unmatched(written, shown) { |w, s| written_matches?(w, s) }
          .map { |w| "#{label}: Rigor records #{owner} → #{w}, which Ruby does not show" } +
          unmatched(shown, written) { |s, w| written_matches?(w, s) }
          .map { |s| "#{label}: Ruby shows #{owner} → #{s}, which Rigor does not record" }
      end
    end

    # The entries of `left` no entry of `right` matches.
    def unmatched(left, right, &match)
      left.reject { |l| right.any? { |r| match.call(l, r) } }
    end

    def def_nestings_violations(runtime, tables, root)
      def_nodes(root).filter_map do |def_node|
        recorded = tables.discovered_def_nestings[def_node]
        line = def_node.location.start_line
        actual = runtime.dig("nestings", line.to_s)
        next if recorded.nil? || actual.nil? || recorded == actual.select { |name| nameable?(name) }

        "def_nestings: Rigor records #{recorded.inspect} for the def at line #{line}; Ruby's is #{actual.inspect}"
      end
    end

    def def_nodes(node, found = [])
      found << node if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each { |child| def_nodes(child, found) }
      found
    end

    def class_cvars_violations(runtime, tables, _root)
      tables.class_cvars.flat_map do |owner, cvars|
        cvars.filter_map do |cvar, type|
          ancestors = runtime.dig("modules", owner, "class_variables", cvar.to_s)
          next if ancestors.nil? || admits?(type, ancestors)

          "class_cvars: Rigor types #{owner} #{cvar} as #{type.describe}; Ruby holds a #{ancestors.first}"
        end
      end
    end

    # Whether a type admits a value whose class has these ancestors. A type this check cannot judge admits it.
    def admits?(type, ancestors)
      case type
      when Rigor::Type::Union then type.members.any? { |member| admits?(member, ancestors) }
      when Rigor::Type::Nominal then ancestors.include?(type.class_name)
      when Rigor::Type::Constant then ancestors.include?(type.value.class.name)
      else true
      end
    end
  end
end
