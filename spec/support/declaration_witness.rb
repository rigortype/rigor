# frozen_string_literal: true

require "bundler"
require "json"
require "open3"
require "prism"
require "rbconfig"

# #1507 — the declaration-fact witness (ADR-119 WD5, proposed). It runs a fixture in a child process under the Ruby
# running the suite (the Flake's locally, CI's on CI), with the bundle stripped and a time limit, records what Ruby
# itself says about the modules the fixture declares, and compares that with the discovery index `rigor check`
# analyses the file under. `violations` returns one line per disagreement; an empty list means the tables agree.
#
# What Ruby is asked, per module the fixture opens or creates:
#
# - `Module.nesting` at every line the fixture runs, with the `self` of that line, so two statements on one line are
#   told apart. A `def` is a statement, so its line carries the nesting its body is compiled under, `class << self`
#   bodies included (a `:class` TracePoint does not report those). Each anonymous entry (`#<Class:C>`) records,
#   after the fixture has loaded, whether it owns constants: its own, and for the innermost entry also its
#   ancestors' up to `Class` / `Module` / `Object` (an `extend M`'s, a superclass's `class << self`'s);
# - its own instance methods by visibility, and its own singleton methods plus those its singleton mixins (`extend`)
#   give it, each with `Method#source_location`;
# - its ancestors, split into its own instance mixins and its own singleton mixins, and its superclass;
# - the class of each class variable's value, for the fixtures that assign one.
#
# The relations:
#
# - A set-valued table must satisfy `certain ⊆ runtime ⊆ certain ∪ possible`. Rigor keeps no `possible` table yet, so
#   every entry reads as `certain` and the relation is equality, with one exception. A self-extend edge that Ruby
#   does not show, which is how the tables model a bare `module_function` (#526's deliberate over-approximation),
#   reads as `possible`, and so do the singleton names and def nodes the extends fold derives from it.
# - A single-valued table must agree with Ruby wherever it answers. No entry is a decline, which is always allowed.
# - Def identity is compared through `source_location` lines.
# - A typed table must admit the class of the value Ruby holds.
# - A def nesting must equal Ruby's once anonymous entries are dropped, and an anonymous entry that owns constants
#   cannot be dropped: a recorded chain without it resolves those constants somewhere else, so Rigor must record
#   no chain for that def.
#
# A module under an anonymous one (`#<Class:…>::D`) is left out of the runtime sets, because no constant path reaches
# it. A runtime method counts only when its `source_location` is in the fixture, so a reopened core class brings only
# the fixture's own methods.
#
# Threat model: the witness checks the fixtures it is given; it finds no bug a fixture does not exercise, and one run
# witnesses one execution. A constant an anonymous cref gains at run time after load (`const_set` from a method) is
# not seen.
module DeclarationWitness
  RELATIONS = %i[
    classes methods visibilities def_nodes singleton_def_nodes superclasses includes extends def_nestings class_cvars
  ].freeze
  # Seconds a fixture may run before the child is killed.
  TIME_LIMIT = 20

  # Runs in the child: `ruby -e RECORDER fixture.rb`, printing one JSON document.
  RECORDER = <<~'RUBY'
    require "json"

    path = File.expand_path(ARGV.fetch(0))
    name_of = ->(mod) { mod.name || mod.inspect }
    in_fixture = ->(location) { location && File.expand_path(location[0]) == path ? location[1] : nil }
    # Whether an anonymous cref makes a constant reachable that no named cref of the chain can: its own constants
    # and, for the innermost cref, its ancestors' up to `Class` / `Module` / `Object`, whose constants the
    # top-level lookup reaches anyway. Read after the fixture has loaded, so a constant written later in the body
    # (it is there when the method runs) counts.
    owns_constants = lambda do |mod, innermost|
      scope = innermost ? mod.ancestors.take_while { |a| ![Class, Module, Object].include?(a) } : [mod]
      scope.any? { |owner| !owner.constants(false).empty? }
    end

    nestings = Hash.new { |table, line| table[line] = [] }
    opened = []
    trace = TracePoint.new(:class, :line) do |tp|
      next unless File.expand_path(tp.path) == path

      if tp.event == :class
        opened << tp.self
      else
        seen = [tp.self, tp.binding.eval("Module.nesting")]
        nestings[tp.lineno] << seen unless nestings[tp.lineno].any? { |s, n| s.equal?(tp.self) && n == seen.last }
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

    # The definition `owner` itself holds for `name`, past any prepended module's.
    own_definition = lambda do |owner, name|
      method = owner.instance_method(name)
      method = method.super_method while method && method.owner != owner
      method
    end
    # Where `name` is defined for `mod`'s side `meta_or_mod`, among the owners that side answers through.
    location_in = lambda do |side, owners, name|
      method = side.instance_method(name)
      method = method.super_method while method && !owners.include?(method.owner)
      method && in_fixture.(method.source_location)
    end

    record = modules.to_h do |mod|
      meta = mod.singleton_class
      superclass = mod.is_a?(Class) ? mod.superclass : nil
      # A module's own mixins: its ancestors less the superclass's, which also drops a prepend on the superclass.
      inherited = superclass ? superclass.ancestors : []
      meta_inherited = superclass ? superclass.singleton_class.ancestors : Module.ancestors
      singleton_mixins = meta.ancestors - meta_inherited - [meta]
      singleton_names = (meta.instance_methods + meta.private_instance_methods).select do |n|
        [meta, *singleton_mixins].include?(meta.instance_method(n).owner)
      end
      instance_names = mod.instance_methods(false) + mod.private_instance_methods(false)
      [name_of.(mod), {
        "superclass" => superclass && name_of.(superclass),
        "instance_mixins" => (mod.ancestors - inherited - [mod]).map(&name_of),
        "singleton_mixins" => singleton_mixins.map(&name_of),
        "public" => mod.public_instance_methods(false).map(&:to_s),
        "private" => mod.private_instance_methods(false).map(&:to_s),
        "protected" => mod.protected_instance_methods(false).map(&:to_s),
        "instance_locations" => instance_names.to_h { |n| [n.to_s, in_fixture.(own_definition.(mod, n)&.source_location)] },
        "singleton_locations" => singleton_names.to_h { |n| [n.to_s, location_in.(meta, [meta, *singleton_mixins], n)] },
        "class_variables" => mod.class_variables(false).to_h do |cv|
          [cv.to_s, mod.class_variable_get(cv).class.ancestors.map(&name_of)]
        end
      }]
    end

    # Each line's `[self, Module.nesting]` pairs, as labels: an anonymous entry carries whether it owns constants.
    labelled = nestings.transform_values do |seen|
      seen.map do |self_value, chain|
        self_label = self_value.is_a?(Module) ? name_of.(self_value) : "(#{self_value.class})"
        [self_label, chain.each_with_index.map { |mod, i| [name_of.(mod), mod.name.nil? && owns_constants.(mod, i.zero?)] }]
      end
    end

    puts JSON.generate("error" => error, "nestings" => labelled, "modules" => record)
  RUBY

  module_function

  # Every disagreement between Ruby and Rigor's tables for the fixture at `path`, restricted to `relations`.
  def violations(path, relations: RELATIONS)
    runtime = record(path)
    tables, root = rigor_tables(path)
    relations.flat_map { |relation| Relations.public_send(:"#{relation}_violations", runtime, tables, root) }
  end

  # What Ruby says about the fixture. A fixture that raises, exits early or runs past {TIME_LIMIT} is a broken
  # fixture, not a finding, and raises here.
  def record(path)
    out, err, status = run_child(path)
    raise "witness recorder failed for #{path} (#{status}): #{err}" unless status&.success?

    runtime = JSON.parse(out)
    raise "witness fixture #{path} raised #{runtime['error']}" if runtime["error"]

    runtime
  rescue JSON::ParserError => e
    raise "witness recorder for #{path} printed no record (#{e.message}): #{err}"
  end

  def run_child(path)
    Bundler.with_unbundled_env do
      Open3.popen3(RbConfig.ruby, "-e", RECORDER, path) do |stdin, stdout, stderr, waiter|
        stdin.close
        readers = [stdout, stderr].map { |io| Thread.new { io.read } }
        unless waiter.join(TIME_LIMIT)
          Process.kill(:KILL, waiter.pid)
          raise "witness fixture #{path} ran past #{TIME_LIMIT}s"
        end
        [readers[0].value, readers[1].value, waiter.value]
      end
    end
  end

  # The discovery index `rigor check` analyses the fixture under: the runner's own project pre-pass and seed
  # (`Runner#ensure_project_discovery`, `#seed_project_scope`), then the file's `ScopeIndexer.index` merge.
  def rigor_tables(path)
    runner = Rigor::Analysis::Runner.new(
      configuration: Rigor::Configuration.new("paths" => [path]), cache_store: nil, collect_stats: false
    )
    runner.send(:ensure_project_discovery, { files: [path] })
    base = runner.send(:seed_project_scope, Rigor::Scope.empty(source_path: path))
    root = Prism.parse(File.read(path), filepath: path).value
    [Rigor::Inference::ScopeIndexer.index(root, default_scope: base).default.discovery, root]
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
        actual = ruby_nesting(runtime, def_node)
        next if recorded.nil? || actual.nil?

        nesting_violation(recorded, actual, def_node.location.start_line)
      end
    end

    def nesting_violation(recorded, actual, line)
      owners = actual.select { |_, owns_constants| owns_constants }.map(&:first)
      unless owners.empty?
        return "def_nestings: Rigor records #{recorded.inspect} for the def at line #{line}; Ruby's nesting holds " \
               "#{owners.join(', ')}, which owns constants the recorded chain cannot reach"
      end
      names = actual.map(&:first)
      return if recorded == names.select { |name| nameable?(name) }

      "def_nestings: Rigor records #{recorded.inspect} for the def at line #{line}; Ruby's is #{names.inspect}"
    end

    # Ruby's nesting for a def: the one its line ran under with the def's own definee as `self`. Without a runtime
    # owner (the def never ran), the line's nesting when only one was seen there.
    def ruby_nesting(runtime, def_node)
      seen = runtime.dig("nestings", def_node.location.start_line.to_s) || []
      selves = definee_selves(runtime, def_node.name.to_s, def_node.location.start_line)
      matching = selves.empty? ? seen : seen.select { |entry| selves.include?(entry.first) }
      chains = matching.map(&:last).uniq
      chains.first if chains.size == 1
    end

    # The `self` values a def statement at `line` naming `name` ran under: each module Ruby filed it in, and that
    # module's singleton class for a singleton method.
    def definee_selves(runtime, name, line)
      runtime["modules"].flat_map do |owner, record|
        selves = []
        selves << owner if record["instance_locations"][name] == line
        selves.push(owner, "#<Class:#{owner}>") if record["singleton_locations"][name] == line
        selves
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
