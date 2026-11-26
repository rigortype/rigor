# frozen_string_literal: true

require "json"
require "prism"
require "yaml"

# #1507 — the source census the declaration-fact gates share (`spec/rigor/declaration_facts/`). Both gates parse the
# Ruby files under `lib/` and `plugins/*/lib/` with Prism, so a mention in a comment or a string never counts. A
# plugin's specs and demo apps are not producers or readers and are left out.
#
# Threat model, for every gate built on this file: they catch an accidental addition written in the codebase's
# normal styles. They do not catch deliberate evasion, and each spec names the forms it does not see.
module DeclarationFactSources
  REPO_ROOT = File.expand_path("../..", __dir__)
  REGENERATE_ENV = "RIGOR_REGENERATE_GATES"

  module_function

  def paths_under(base = REPO_ROOT)
    (Dir.glob("lib/**/*.rb", base: base) + Dir.glob("plugins/*/lib/**/*.rb", base: base)).sort
  end

  # `{relative path => Prism root}` for every covered file under `base`, parsed once per base.
  def parsed_under(base = REPO_ROOT)
    @parsed ||= {}
    @parsed[base] ||= paths_under(base).to_h do |path|
      [path, Prism.parse_file(File.join(base, path)).value]
    end
  end

  # Whether the run asked to rewrite the committed snapshots instead of comparing with them.
  def regenerate?
    ENV[REGENERATE_ENV] == "1"
  end

  def yaml_text(header, data)
    header + YAML.dump(data, line_width: -1).delete_prefix("---\n")
  end

  def write_yaml(path, header, data)
    File.write(path, yaml_text(header, data))
  end

  # `producers.yml` brought in line with `keys` (`"path#scope"`) by editing its text, not by re-dumping it: the file's
  # reasons are hand-written scalars, quoted or folded where they hold ` #`, and a load and dump would reorder
  # entries, refold a `>-` block and drop the quoting the author chose. An entry that is still found keeps its lines
  # as they are, a new one is added as `TODO` before the first existing entry that sorts after it, a vanished one
  # (and a file left with none) is dropped, and the leading comment block stays. Returns the new text.
  def regenerate_producers_text(text, keys)
    text += "\n" unless text.empty? || text.end_with?("\n")
    head, sections = split_producer_sections(text)
    wanted = keys.group_by { |key| key.split("#", 2).first }
                 .transform_values { |paths| paths.map { |key| key.split("#", 2).last } }
    kept = sections.filter_map do |path, preamble, entries|
      [path, preamble, merge_producer_entries(entries, wanted[path])] if wanted.key?(path)
    end
    add_producer_sections(kept, wanted.slice(*(wanted.keys - sections.map(&:first))))
    lines = kept.flat_map { |_path, preamble, entries| [*preamble, *entries.flat_map(&:last)] }
    head.join + lines.join
  end

  def add_producer_sections(kept, added)
    added.sort.each do |path, scopes|
      at = kept.index { |section| section.first > path } || kept.size
      preamble = ["#{yaml_key(path)}:\n", "  computes: TODO\n", "  producers:\n"]
      kept.insert(at, [path, preamble, merge_producer_entries([], scopes)])
    end
  end

  def yaml_key(text)
    YAML.safe_load("#{text}: x") == { text => "x" } ? text : text.to_json
  rescue Psych::Exception
    text.to_json
  end

  # `[head lines, [[path, preamble lines, [[scope, entry lines]]]]]`; a preamble is a file's header line and the lines
  # up to and including `  producers:`, and only after that line does a 4-space `key:` start an entry (before it, such
  # a line continues a multi-line `computes:`). An entry is its `key: reason` line and any continuation lines.
  def split_producer_sections(text)
    head = []
    sections = []
    text.each_line do |line|
      if line.match?(/\A\S/) && !line.start_with?("#")
        sections << [unquote_yaml_key(line.chomp.delete_suffix(":")), [line], []]
      elsif sections.empty?
        head << line
      else
        add_producer_line(sections.last, line)
      end
    end
    [head, sections]
  end

  def add_producer_line(section, line)
    _, preamble, entries = section
    match = line.match(/\A {4}(\S.*?):(?: |$)/) if preamble.any? { |text| text.start_with?("  producers:") }
    if match
      entries << [unquote_yaml_key(match[1]), [line]]
    elsif entries.empty?
      preamble << line
    else
      entries.last.last << line
    end
  end

  # The inverse of `yaml_key`'s quoting.
  def unquote_yaml_key(text)
    text.start_with?('"') ? JSON.parse(text) : text
  end

  def merge_producer_entries(entries, scopes)
    merged = entries.to_h.slice(*(entries.map(&:first) & scopes)).to_a
    (scopes - entries.map(&:first)).sort.each do |scope|
      at = merged.index { |existing, _| existing > scope } || merged.size
      merged.insert(at, [scope, ["    #{yaml_key(scope)}: TODO\n"]])
    end
    merged
  end

  # The full name of a constant reference, or nil for a dynamic path (`foo::Bar`).
  def constant_name(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode then node.full_name
    end
  rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
    nil
  end

  # Every node under `node`, depth first, the root included.
  def each_node(node, &)
    return enum_for(:each_node, node) unless block_given?

    yield node
    node.compact_child_nodes.each { |child| each_node(child, &) }
  end

  # Yields `node, owners` for every node, `owners` being the lexical class and module names around it.
  def each_with_owners(node, owners = [], &)
    yield node, owners
    inner = owners
    if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      name = constant_name(node.constant_path) || "(dynamic)"
      inner = name.start_with?("::") ? [name.delete_prefix("::")] : owners + [name]
    end
    node.compact_child_nodes.each { |child| each_with_owners(child, inner, &) }
  end

  # The qualified names a constant reference written under `owners` may denote, innermost first.
  def candidates(name, owners)
    return [name.delete_prefix("::")] if name.start_with?("::")

    (0..owners.size).map { |size| (owners.first(owners.size - size) + [name]).join("::") }
  end
end

# ADR-119 WD6's producer tripwire (proposed): the methods, and the class or module bodies, whose code decides what a
# declaration is. A scope is a producer when its code
#
# - (i) references `Prism::ClassNode`, `Prism::ModuleNode` or `Prism::SingletonClassNode`, or defines a
#   `Prism::Visitor` hook for one (`visit_class_node`, …);
# - (ii) names a node-type symbol (`:class_node`, …);
# - (iii) references a constant, in this file or another covered one, whose assignment contains (i), (ii) or (iv);
# - (iv) names a visibility or mixin keyword as a symbol (`:private`, `:include`, …), except as a Hash key or among
#   Array/String mutator names (`%i[<< push prepend unshift]` names methods, not the keyword);
# - (v) in a file `DeclarationWriterScan::SOURCES` lists, is reachable through same-file calls (in its body or
#   default arguments) from one of the roots that table gives the file or a method another covered file calls on
#   the file's module (`ScopeIndexer.x`), and writes into one of its parameters, a `*rest` or `**rest` included: an
#   indexed assignment or a `<<` / `merge!` / `add?`-style call into it, or passing it (by position, keyword or
#   splat) to a method that does, of the same file or of another listed file, called on that file's module by name
#   (`ScopeIndexer.add_header_nesting(table, …)` from a module under `scope_indexer/`, #3398).
#
# A class that includes `DeclarationWalk::Collector` is a producer as a whole, found from the `include` statement, and
# so is a class in a covered file whose superclass is one (`class X < SuperclassesCollector`).
module DeclarationProducerScan
  NODE_CONSTANTS = %w[Prism::ClassNode Prism::ModuleNode Prism::SingletonClassNode].freeze
  NODE_TYPES = %i[class_node module_node singleton_class_node].freeze
  VISITOR_HOOKS = %i[visit_class_node visit_module_node visit_singleton_class_node].freeze
  KEYWORDS = %i[private protected public module_function include extend prepend].freeze
  # Names only an Array or String mutator catalogue lists; a keyword symbol beside one of them names a method.
  MUTATORS = %i[<< push append unshift insert concat pop shift replace clear fill delete_at slice! sub! gsub!].freeze
  # Rule (v)'s first file. `DeclarationWriterScan::SOURCES` lists every file the rule follows.
  RULE_V_FILE = "lib/rigor/inference/scope_indexer.rb"
  DEFINE_METHOD_CALLS = %i[define_method define_singleton_method].freeze

  module_function

  # `{"path#scope" => [reasons]}` over the parsed files; `sources` is rule (v)'s table.
  def producers(parsed, sources = DeclarationWriterScan::SOURCES)
    tainted = tainted_constants(parsed)
    found = Hash.new { |table, key| table[key] = [] }
    parsed.each do |path, root|
      skipped = catalogue_symbols(root)
      scan(root, [], nil, tainted, skipped) { |scope, reason| found["#{path}##{scope}"] << reason }
    end
    collectors(parsed) { |path, scope, why| found["#{path}##{scope}"] << why }
    DeclarationWriterScan.each_writer(parsed, sources) do |path, scope|
      found["#{path}##{scope}"] << "writes a table (rule v)"
    end
    found.transform_values(&:uniq)
  end

  # The reason `node` makes its scope a producer, or nil.
  def reason(node, owners, tainted, skipped)
    case node
    when Prism::ConstantPathNode, Prism::ConstantReadNode then constant_reason(node, owners, tainted)
    when Prism::SymbolNode
      value = node.unescaped.to_sym
      return ":#{value}" if NODE_TYPES.include?(value)

      ":#{value}" if KEYWORDS.include?(value) && !skipped.include?(node)
    when Prism::DefNode then ":#{node.name} (a Prism::Visitor hook)" if VISITOR_HOOKS.include?(node.name)
    end
  end

  def constant_reason(node, owners, tainted)
    name = DeclarationFactSources.constant_name(node)
    return nil unless name
    return name.delete_prefix("::") if NODE_CONSTANTS.include?(name.delete_prefix("::"))

    hit = DeclarationFactSources.candidates(name, owners).find { |candidate| tainted.include?(candidate) }
    "#{hit} (a constant built from one)" if hit
  end

  # The keyword symbols listed beside a mutator name: in one Array literal, `when` clause or argument list.
  def catalogue_symbols(root)
    skipped = Set.new.compare_by_identity
    DeclarationFactSources.each_node(root) do |node|
      siblings = case node
                 when Prism::ArrayNode then node.elements
                 when Prism::WhenNode then node.conditions
                 when Prism::ArgumentsNode then node.arguments
                 else next
                 end
      symbols = siblings.grep(Prism::SymbolNode)
      next unless symbols.any? { |symbol| MUTATORS.include?(symbol.unescaped.to_sym) }

      symbols.each { |symbol| skipped << symbol }
    end
    skipped
  end

  # The qualified constants, across all parsed files, whose assignment contains a producer reference.
  def tainted_constants(parsed)
    writes = parsed.flat_map do |_, root|
      skipped = catalogue_symbols(root)
      found = []
      DeclarationFactSources.each_with_owners(root) do |node, owners|
        target = constant_write_target(node)
        found << [(owners + [target]).join("::"), node.value, owners, skipped] if target
      end
      found
    end
    grow_taint(writes)
  end

  def constant_write_target(node)
    case node
    when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then node.name.to_s
    when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode
      DeclarationFactSources.constant_name(node.target)
    end
  end

  def grow_taint(writes)
    tainted = Set.new
    loop do
      grown = writes.reject { |write| tainted.include?(write.first) }.select do |_, value, owners, skipped|
        DeclarationFactSources.each_node(value).any? { |node| reason(node, owners, tainted, skipped) }
      end
      return tainted if grown.empty?

      tainted.merge(grown.map(&:first))
    end
  end

  # Walks `node` under the owner chain `owners`; `scope` is the current method key, nil in a body.
  def scan(node, owners, scope, tainted, skipped, &report)
    owners, scope = enter(node, owners, scope)
    if node.is_a?(Prism::AssocNode)
      scan(node.value, owners, scope, tainted, skipped, &report) if node.value
      return
    end
    found = reason(node, owners.reject { |owner| owner == "<<" }, tainted, skipped)
    report.call(scope || body_key(owners), found) if found
    return if node.is_a?(Prism::ConstantPathNode)

    node.compact_child_nodes.each { |child| scan(child, owners, scope, tainted, skipped, &report) }
  end

  # The owner chain and method key `node`'s children are scanned under.
  def enter(node, owners, scope)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      [owners + [DeclarationFactSources.constant_name(node.constant_path) || "(dynamic)"], nil]
    when Prism::SingletonClassNode then [owners + ["<<"], nil]
    when Prism::DefNode then [owners, def_key(owners, node, node.receiver)]
    when Prism::CallNode then [owners, define_method_key(node, owners) || scope]
    else [owners, scope]
    end
  end

  # `define_method(:name) { … }` defines a method of its own.
  def define_method_key(node, owners)
    return nil unless DEFINE_METHOD_CALLS.include?(node.name) && node.block.is_a?(Prism::BlockNode)

    first = node.arguments&.arguments&.first
    return nil unless first.is_a?(Prism::SymbolNode)

    def_key(owners, first.unescaped, node.name == :define_singleton_method)
  end

  def body_key(owners)
    owners.empty? ? "(top level)" : owners.join("::").gsub("::<<", " << self")
  end

  def def_key(owners, node_or_name, receiver)
    name = node_or_name.respond_to?(:name) ? node_or_name.name : node_or_name
    singleton = receiver || owners.last == "<<"
    owner = owners.reject { |o| o == "<<" }.join("::")
    "#{owner.empty? ? '(top level)' : owner}#{singleton ? '.' : '#'}#{name}"
  end

  # Yields `path, body key, reason` for every class that includes `DeclarationWalk::Collector`, then for every class
  # in a covered file whose superclass names one of those, transitively.
  def collectors(parsed)
    found = []
    subclasses = []
    parsed.each do |path, root|
      DeclarationFactSources.each_with_owners(root) do |node, owners|
        if collector_include?(node, owners)
          found << [path, owners.join("::"), "include DeclarationWalk::Collector"]
        elsif node.is_a?(Prism::ClassNode) && (superclass = DeclarationFactSources.constant_name(node.superclass))
          subclasses << [path, class_key(node, owners), superclass, owners]
        end
      end
    end
    grow_collectors(found, subclasses).each { |entry| yield(*entry) }
  end

  def grow_collectors(found, subclasses)
    names = found.to_set { |_, key, _| key }
    loop do
      grown = subclasses.reject { |_, key, _, _| names.include?(key) }.select do |_, _, superclass, owners|
        DeclarationFactSources.candidates(superclass, owners).any? { |candidate| names.include?(candidate) }
      end
      return found if grown.empty?

      grown.each do |path, key, superclass, _|
        names << key
        found << [path, key, "#{superclass} (a DeclarationWalk::Collector subclass)"]
      end
    end
  end

  def collector_include?(node, owners)
    return false unless node.is_a?(Prism::CallNode) && node.name == :include && node.receiver.nil?

    names = (node.arguments&.arguments || []).filter_map { |arg| DeclarationFactSources.constant_name(arg) }
    names.any? { |name| collector_name?(name, owners) }
  end

  def class_key(node, owners)
    name = DeclarationFactSources.constant_name(node.constant_path) || "(dynamic)"
    name.start_with?("::") ? name.delete_prefix("::") : (owners + [name]).join("::")
  end

  def collector_name?(name, owners)
    name.end_with?("DeclarationWalk::Collector") || (name == "Collector" && owners.include?("DeclarationWalk"))
  end
end

# ADR-119 WD6's rule (v): the methods of each file `SOURCES` lists that are reachable, through same-file calls (a
# default argument's included), from the file's roots or from a method another covered file calls on the file's
# module (`ScopeIndexer.x`, `NodePropagation.x`), and write into one of their parameters: an indexed assignment or a
# `<<` / `merge!`-style call into it, or passing it to a method that does, of the same file or of another listed file
# called on its module by name (#3398).
module DeclarationWriterScan
  # Rule (v)'s table, a row per file: the module whose functions the file defines, by its full name, and the roots
  # the rule starts from in that file. A method another covered file calls on the module (`names?`) is a root as
  # well, whether or not its caller is reachable, so a new entry point needs no edit here, and a file entered only
  # that way (`roots: []`) is a root set of its own: reachability is followed inside a file and never from one file
  # into the next. A parameter write is followed across rows: handing a table to a writer of another row's file,
  # called on that row's module by name, writes it (#3398). A module that leaves `scope_indexer.rb` with a table
  # writer is one more row, without which the rule no longer follows it. `source_problems` fails a row whose file,
  # module or root is gone.
  #
  # - `scope_indexer.rb`: ADR-119's three roots, then the multi-file entry points, whose folds
  #   (`finalize_project_index`, `fold_def_tables`, `fold_def_sources`, …) are reachable from no other root.
  # - `node_propagation.rb`: the per-node propagation, moved out of `scope_indexer.rb` (ADR-116 WD10); its `table`
  #   writers stay rule (v)'s. `scope_indexer.rb`'s delegators enter it as `NodePropagation.x`.
  # - `declaration_signature.rb` and `program_globals.rb`: the declaration signature and the program-global seed,
  #   moved out of `scope_indexer.rb` (ADR-116 WD9, L1 and L4). The writers of the signature's `parts` and of the
  #   seed's accumulator stay rule (v)'s. `scope_indexer.rb` enters each through its one function,
  #   `DeclarationSignature.declaration_signature` and `ProgramGlobals.seed_program_globals`.
  # - `declaration_walk/rules.rb`: the declaration-context rules, moved out of `scope_indexer.rb` (ADR-116 WD9, R1).
  #   The walk behind the declared-names oracle (`collect_declared_constant_names` and its arms) writes its `names`
  #   set and stays rule (v)'s. Every caller spells the module out, as `DeclarationWalk::Rules.x` or, inside the walk,
  #   `Rules.x`; a call through an alias of the module would not be a root.
  # - `class_declarations.rb`, `literal_receiver_mutations.rb` and `published_constant_ivars.rb`: the class-declaration
  #   walk, the mutation census and the published-constant ivar census, moved out of `scope_indexer.rb` (ADR-116 WD9,
  #   U1 to U3). The writers of each walk's accumulator, census or table stay rule (v)'s. Each is entered through its
  #   one function, spelled on the module: `ClassDeclarations.collect_class_decls`,
  #   `LiteralReceiverMutations.collect_literal_receiver_mutations` (which `constant_ivar_value.rb` calls too) and
  #   `PublishedConstantIvars.seed_published_constant_ivars`.
  # - `class_cvar_census.rb`: the class-variable census, moved out of `scope_indexer.rb` (ADR-116 WD9, U5). The
  #   writers of its accumulator stay rule (v)'s. It is entered through four functions, each spelled on the module:
  #   `ClassCvarCensus.build_class_cvar_index` from `scope_indexer.rb`, and `collect_def_cvar_writes`,
  #   `collect_body_cvar_writes` and `finished_cvar_census` from `class_cvars_collector.rb`. Its two calls of
  #   `ScopeIndexer.census_body_scope` make that function an entry point of `scope_indexer.rb`, where the row's
  #   roots reached it already and it writes no table.
  # - `shared_walk_tables.rb`: the tables one shared walk builds, their recorders and the walkers the collectors
  #   replaced, moved out of `scope_indexer.rb` (ADR-116 WD9, U4). The writers of each table stay rule (v)'s. It is
  #   entered through eight functions, each spelled on the module: `SharedWalkTables.declaration_walk_tables`,
  #   `meta_member_names` and `meta_members_open?` from `scope_indexer.rb`, the four recorders from
  #   `superclasses_collector.rb` and `member_layouts_collector.rb`, and `recorded_ancestor_name` from
  #   `cvar_hierarchy.rb`. Its calls of `ScopeIndexer.add_header_nesting` and `rebound_block_self` make those two
  #   entry points of `scope_indexer.rb`. The first writes the header-nesting table and keeps its row there; moved
  #   into this file, it would keep it here, since it hands the table to `ScopeIndexer.merge_header_nesting_bucket`
  #   and rule (v) follows a write into another row (#3398).
  # - `mutated_carrier_widening.rb`, `factory_call_resolver.rb` and `singleton_class_sources.rb`: the widening of the
  #   carriers a file mutates in place, the factory call an expression unwinds to, and the constants whose singleton
  #   side a file writes to without declaring them, moved out of `scope_indexer.rb` (ADR-116 WD9, #3400). The last
  #   writes the `sources` table it is handed, and that writer stays rule (v)'s. The first two write no parameter
  #   today: the wideners answer a copy of the table they take, and the resolver takes none. Each has a row all the
  #   same, so that the rule reads what it read while they were in `scope_indexer.rb`: a write into a table handed
  #   to one of them would be listed, there and in the caller that handed it over (#3398). Each is entered through
  #   the functions other covered files spell on its module: `MutatedCarrierWidening.widen_mutated_constants`,
  #   `widen_mutated_cvars`, `census_mutated_type` and `census_unpinned_content`;
  #   `FactoryCallResolver.resolve_meta_factory_call`; `SingletonClassSources.record_singleton_class_sources`. The
  #   last module's calls of `ScopeIndexer.singleton_receiver_constant_name` and `surface_rewriting_call?` make
  #   those two entry points of `scope_indexer.rb`, where neither writes a table.
  SOURCES = {
    DeclarationProducerScan::RULE_V_FILE => {
      module: "Rigor::Inference::ScopeIndexer",
      roots: %i[
        index accumulate_project_index finalize_def_index
        discovered_classes_for_paths discovered_def_index_for_paths discovered_project_index_for_paths
        discovered_project_index_incremental scan_summary_for_paths
      ]
    },
    "lib/rigor/inference/scope_indexer/node_propagation.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::NodePropagation", roots: [] },
    "lib/rigor/inference/scope_indexer/declaration_signature.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::DeclarationSignature", roots: [] },
    "lib/rigor/inference/scope_indexer/program_globals.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::ProgramGlobals", roots: [] },
    "lib/rigor/inference/scope_indexer/class_declarations.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::ClassDeclarations", roots: [] },
    "lib/rigor/inference/scope_indexer/literal_receiver_mutations.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::LiteralReceiverMutations", roots: [] },
    "lib/rigor/inference/scope_indexer/published_constant_ivars.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::PublishedConstantIvars", roots: [] },
    "lib/rigor/inference/scope_indexer/class_cvar_census.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::ClassCvarCensus", roots: [] },
    "lib/rigor/inference/scope_indexer/shared_walk_tables.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::SharedWalkTables", roots: [] },
    "lib/rigor/inference/scope_indexer/mutated_carrier_widening.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::MutatedCarrierWidening", roots: [] },
    "lib/rigor/inference/scope_indexer/factory_call_resolver.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::FactoryCallResolver", roots: [] },
    "lib/rigor/inference/scope_indexer/singleton_class_sources.rb" =>
      { module: "Rigor::Inference::ScopeIndexer::SingletonClassSources", roots: [] },
    "lib/rigor/inference/declaration_walk/rules.rb" => { module: "Rigor::Inference::DeclarationWalk::Rules", roots: [] }
  }.freeze

  module_function

  # Rule (v) over the table: yields `path, key` for each method of a listed file that is reachable from the file's
  # entry points and writes into a parameter, directly or by handing it to a writer of its own file or of another
  # listed file. A file `parsed` does not hold yields nothing, and a root its file does not define starts nothing, so
  # that a part of the tree can be scanned; `source_problems` reports both.
  def each_writer(parsed, sources = SOURCES)
    rows = sources.select { |path, _| parsed.key?(path) }
    units = units(rows.to_h { |path, _| [path, definitions(parsed.fetch(path))] }, rows)
    calls = unit_calls(units, rows)
    writers = parameter_writers(units, calls)
    outside = module_calls(parsed)
    rows.each do |path, source|
      reachable(path, calls, entry_points(outside, path, source)).each do |name|
        next if writers.fetch([path, name]).empty?

        units.fetch([path, name]).each do |node, owners|
          yield path, DeclarationProducerScan.def_key(owners, node, node.receiver)
        end
      end
    end
  end

  # What makes a row follow less than it says, a line each: a file that is not covered (moved or renamed), a file
  # that defines no method of the row's module, a root that is not a method of that module there (moved out or
  # renamed), and a file the rule starts nowhere in.
  def source_problems(parsed, sources = SOURCES)
    calls = module_calls(parsed)
    sources.flat_map do |path, source|
      root = parsed[path]
      next ["#{path}: listed for rule (v), but not a covered file"] unless root

      row_problems(path, source, definitions(root), entry_points(calls, path, source))
    end
  end

  def row_problems(path, source, defs, entries)
    name = source.fetch(:module)
    own = defs.select { |_, sites| sites.any? { |_, owners| owners.join("::") == name } }.keys
    return ["#{path}: defines no method of #{name}"] if own.empty?

    problems = (source.fetch(:roots) - own).map { |root| "#{path}: root #{root} is not a method of #{name} here" }
    unless entries.intersect?(own)
      problems << "#{path}: rule (v) starts nowhere, no root of its row and no call on #{name} from another " \
                  "covered file naming a method here"
    end
    problems
  end

  # `[[path, method name, the receiver's constant name]]` for every call on a constant in the parsed files.
  def module_calls(parsed)
    parsed.flat_map do |path, root|
      DeclarationFactSources.each_node(root).filter_map do |node|
        name = DeclarationFactSources.constant_name(node.receiver) if node.is_a?(Prism::CallNode)
        [path, node.name, name] if name
      end
    end
  end

  # A file's entry points: the roots its row lists, and the methods the other covered files call on its module.
  def entry_points(calls, path, source)
    called = calls.filter_map do |caller_path, method, name|
      method if caller_path != path && names?(name, source.fetch(:module))
    end
    source.fetch(:roots) | called
  end

  # Whether a constant reference names the module: by its full name or a trailing part of it that starts at a `::`
  # (`Rules`, `DeclarationWalk::Rules`), so that `CheckRules` and `Analysis::Rules` do not name
  # `Rigor::Inference::DeclarationWalk::Rules`; a reference anchored with a leading `::`, by the full name only. The
  # spelling alone decides: a module of another namespace written with the same trailing name is taken too, and an
  # alias constant spelled otherwise is not seen.
  def names?(reference, module_name)
    return reference.delete_prefix("::") == module_name if reference.start_with?("::")

    module_name == reference || module_name.end_with?("::#{reference}")
  end

  # `{method name => [[def node, owners]]}` for a file. Every definition of a name counts: a reopening or a
  # `def self.x` beside a `module_function` copy.
  def definitions(root)
    defs = Hash.new { |table, name| table[name] = [] }
    DeclarationFactSources.each_with_owners(root) do |node, owners|
      defs[node.name] << [node, owners] if node.is_a?(Prism::DefNode)
    end
    defs
  end

  # Rule (v)'s units, each `key => [[def node, owners]]`: `[path, name]` holds every def of the name in a listed
  # file, which a call from the same file reaches; `[path, name, module]` holds those of the row's module (an owner
  # `names?` reads as it), which a call on the module by name from another listed file reaches, so that a nested
  # class's def of the name is not taken for the module's.
  def units(defs, rows)
    defs.each_with_object({}) do |(path, file), units|
      module_name = rows.fetch(path).fetch(:module)
      file.each do |name, sites|
        units[[path, name]] = sites
        own = sites.select { |_, owners| names?(owners.join("::"), module_name) }
        units[[path, name, module_name]] = own unless own.empty?
      end
    end
  end

  # `{unit key => [[callee unit key, call node]]}`: the calls each unit's defs make into a unit, worked out once per
  # def.
  def unit_calls(units, rows)
    made = {}.compare_by_identity
    units.to_h do |key, sites|
      [key, sites.flat_map { |def_node, _| made[def_node] ||= def_calls(key.first, def_node, units, rows) }]
    end
  end

  def def_calls(path, def_node, units, rows)
    def_code(def_node).grep(Prism::CallNode).flat_map do |node|
      callee_keys(path, node, rows).filter_map { |callee| [callee, node] if units.key?(callee) }
    end
  end

  # Every node a def runs: its default arguments and its body.
  def def_code(def_node)
    [def_node.parameters, def_node.body].compact.flat_map { |part| DeclarationFactSources.each_node(part).to_a }
  end

  # The units a call can run: on the implicit receiver or `self`, or on the file's own module by name, the file's
  # defs of the name; on another listed module by name, that module's own defs of it in its file.
  def callee_keys(path, node, rows)
    receiver = node.receiver
    return [[path, node.name]] if receiver.nil? || receiver.is_a?(Prism::SelfNode)

    name = DeclarationFactSources.constant_name(receiver)
    return [] if name.nil?

    rows.filter_map do |callee, source|
      module_name = source.fetch(:module)
      next unless names?(name, module_name)

      callee == path ? [path, node.name] : [callee, node.name, module_name]
    end
  end

  # The methods of `path` reachable from `roots` through its calls into its own file.
  def reachable(path, calls, roots)
    seen = Set.new
    pending = roots.select { |root| calls.key?([path, root]) }
    until pending.empty?
      name = pending.pop
      next unless seen.add?(name)

      pending.concat(calls.fetch([path, name]).filter_map { |callee, _| callee[1] if callee.first == path })
    end
    seen
  end

  # `{unit key => Set[parameter names it writes]}`, directly or by passing one to a writer it calls.
  def parameter_writers(units, calls)
    params = units.transform_values do |sites|
      sites.flat_map { |node, _| DeclarationParameterWrites.parameter_names(node) }.uniq
    end
    writes = units.to_h do |key, sites|
      written = sites.map { |node, _| DeclarationParameterWrites.direct_writes(node, params.fetch(key)) }
      [key, written.reduce(Set.new, :|)]
    end
    loop { return writes unless grow_writes(units, calls, params, writes) }
  end

  # One pass of `parameter_writers`' fixpoint: adds to `writes` each parameter a caller hands to one its callee
  # writes, and answers whether it added any.
  def grow_writes(units, calls, params, writes)
    grown = false
    calls.each do |key, sites|
      sites.each do |callee, site|
        handed = DeclarationParameterWrites.passed_writes(site, units.fetch(callee), params.fetch(key),
                                                          writes.fetch(callee))
        handed.each { |param| grown = true if writes.fetch(key).add?(param) }
      end
    end
    grown
  end
end

# Rule (v)'s parameter writes: which parameters a def writes into itself, and which of a caller's parameters a call
# hands to a parameter its callee writes. `DeclarationWriterScan` runs the fixpoint over them.
module DeclarationParameterWrites
  # The Hash / Set / Array writers, then the visibility table's own (`ScopeIndexer::VisibilityTable#write` and the
  # contest writers beside it), which write a slot or its contest as `[]=` does (#1984).
  WRITE_CALLS = %i[
    []= << push unshift concat merge! store add add? update write wrote contest_slot contest_class
  ].freeze

  module_function

  # Every named parameter, a `*rest` and a `**rest` included.
  def parameter_names(def_node)
    list = def_node.parameters
    return [] unless list

    names_of([*list.requireds, *list.optionals, list.rest, *list.posts, *list.keywords, list.keyword_rest])
  end

  # The parameters positional argument `index` can land in: a leading one, else the `*rest` that absorbs it. A
  # `*splat` can land in any of them from `index` on.
  def positional_targets(list, index, splat)
    return [] unless list

    leading = list.requireds + list.optionals
    return names_of([*leading.drop(index), list.rest, *list.posts]) if splat

    names_of([index < leading.size ? leading[index] : list.rest])
  end

  # The names of the named ones among `params`: an anonymous `*`, `**` or `**nil` has none.
  def names_of(params)
    params.filter_map { |param| param.respond_to?(:name) ? param.name : nil }
  end

  # The parameters `def_node` writes into itself.
  def direct_writes(def_node, params)
    written = Set.new
    DeclarationWriterScan.def_code(def_node).each do |node|
      target = case node
               when Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode then node.receiver
               when Prism::CallNode then node.receiver if WRITE_CALLS.include?(node.name)
               end
      root = target && parameter_root(target, params)
      written << root if root
    end
    written
  end

  # The parameter an expression reads through (`acc`, `acc[k]`, `(acc[k] ||= {})`), or nil.
  def parameter_root(node, params)
    case node
    when Prism::LocalVariableReadNode then params.include?(node.name) ? node.name : nil
    when Prism::CallNode then node.name == :[] && node.receiver ? parameter_root(node.receiver, params) : nil
    when Prism::IndexOrWriteNode, Prism::IndexOperatorWriteNode, Prism::IndexAndWriteNode
      parameter_root(node.receiver, params)
    when Prism::ParenthesesNode
      body = node.body
      body = body.body.last if body.is_a?(Prism::StatementsNode)
      parameter_root(body, params)
    end
  end

  # The caller's parameters a call hands to a parameter the callee writes: by position or keyword, into a `*rest` or
  # `**rest` that absorbs the argument, or as a `*splat` / `**splat`.
  def passed_writes(site, callee_sites, caller_params, callee_writes)
    lists = callee_sites.map { |node, _| node.parameters }
    (site.arguments&.arguments || []).each_with_index.flat_map do |arg, index|
      handed(arg, index, lists).filter_map do |value, targets|
        parameter_root(value, caller_params) if value && targets.any? { |name| callee_writes.include?(name) }
      end
    end
  end

  # `[[value, callee parameters it can land in]]` for one argument.
  def handed(arg, index, lists)
    if arg.is_a?(Prism::KeywordHashNode)
      return arg.elements.map { |element| [element.value, keyword_targets(lists, element)] }
    end

    splat = arg.is_a?(Prism::SplatNode)
    [[splat ? arg.expression : arg, lists.flat_map { |list| positional_targets(list, index, splat) }]]
  end

  # The callee parameters a keyword argument can land in: the keyword itself, else the `**rest` that absorbs it. A
  # `**splat` can land in any of them.
  def keyword_targets(lists, element)
    splat = element.is_a?(Prism::AssocSplatNode)
    key = element.key.unescaped.to_sym if !splat && element.key.is_a?(Prism::SymbolNode)
    lists.compact.flat_map do |list|
      keyword = key && list.keywords.find { |param| param.name == key }
      names_of(keyword ? [keyword] : [*(list.keywords if splat), list.keyword_rest])
    end
  end
end

# WD1's admission census (ADR-119): per `Scope::DiscoveryIndex` member, the files that read the whole table or copy
# it, outside the table owners.
#
# - A full member name counts wherever it appears as a method name or a Symbol: `x.discovered_extends`,
#   `values_at(:discovered_def_nodes)`, `slice(…)`, `method(:…)`, a keyword, a Hash key, a Symbol list. As a call
#   argument it is a read, except under `[]=` / `store`; anywhere else it is a copy.
# - A def-index slot name (the member name without `discovered_`: `:def_sources`, `:refinements`) counts in any
#   argument position of a keyed read (`[]`, `fetch`, `dig`, `key?`, `values_at`, `slice`, …) or write (`[]=`,
#   `store`), on any receiver. `:methods` and `:classes` are ordinary words, so they count only on a receiver named
#   like an index (`index`, `def_index`, `seed`, `tables`, `bundle`, `summary`). A Symbol list naming two or more
#   slots is an alias list and counts as a copy of each, and so does a slot name assigned to a constant or variable
#   of any kind, by `=`, `||=` or a multi-write, alone, frozen or in a list (`SLOT = :def_nodes`,
#   `@@slots ||= %i[def_nodes]`), which stands for the slot wherever it is read.
# - Whole-index reads and copies are recorded apart: `with(**x)`, `new(**x)`, `new(*x)`, `to_h`, `deconstruct` and
#   `deconstruct_keys` on a discovery index, iterating `DiscoveryIndex.members`, a `send` with a computed name on
#   one, and a `discovered_`-prefixed interpolated Symbol or String.
module DiscoveryReadScan
  # The table owners: the index, its keyed readers, the indexer with its collectors, and the pre-pass that builds it.
  EXCLUDED = %w[
    lib/rigor/scope.rb lib/rigor/scope/discovery_index.rb lib/rigor/inference/scope_indexer.rb
    lib/rigor/analysis/runner/project_pre_passes.rb
  ].freeze
  EXCLUDED_DIRECTORY = "lib/rigor/inference/scope_indexer/"
  # The calls that read a table by a key naming it, in any argument position.
  KEY_READ_CALLS = %i[[] fetch dig key? delete values_at slice except].freeze
  WRITE_CALLS = %i[[]= store].freeze
  SEND_CALLS = %i[public_send send __send__].freeze
  AMBIGUOUS_SLOTS = %i[methods classes].freeze
  WHOLE_INDEX_CALLS = %i[to_h deconstruct deconstruct_keys dup clone].freeze
  # The assignments whose value can hold a slot name: every constant and variable form, `||=` and multi-write too.
  SLOT_HOLDERS = [
    Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode,
    Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableWriteNode,
    Prism::InstanceVariableOrWriteNode, Prism::ClassVariableWriteNode, Prism::ClassVariableOrWriteNode,
    Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode, Prism::MultiWriteNode
  ].freeze

  module_function

  # `{Symbol => [member, full]}`: each member's own name, and its short slot name.
  def aliases(members)
    members.each_with_object({}) do |member, table|
      table[member] = [member, true]
      table[member.to_s.delete_prefix("discovered_").to_sym] ||= [member, false]
    end
  end

  # `{"members" => {member => {"reads" => [paths], "copies" => [paths]}}, "whole_index" => [paths]}`.
  def census(parsed, members)
    table = aliases(members)
    result = members.to_h { |member| [member.to_s, { "reads" => Set.new, "copies" => Set.new }] }
    whole = Set.new
    column = { read: "reads", copy: "copies" }
    parsed.except(*EXCLUDED).each do |path, root|
      next if path.start_with?(EXCLUDED_DIRECTORY)

      scan(root, table) do |kind, member|
        if kind == :whole
          whole << path
        else
          result[member.to_s][column.fetch(kind)] << path
        end
      end
    end
    { "members" => result.transform_values { |entry| entry.transform_values { |paths| paths.to_a.sort } },
      "whole_index" => whole.to_a.sort }
  end

  def scan(root, table, &report)
    claimed = Set.new.compare_by_identity
    DeclarationFactSources.each_node(root) do |node|
      case node
      when Prism::CallNode then scan_call(node, table, claimed, &report)
      when Prism::ArrayNode then scan_alias_list(node, table, claimed, &report)
      when *SLOT_HOLDERS then scan_slot_holder(node, table, &report)
      when Prism::InterpolatedSymbolNode, Prism::InterpolatedStringNode
        report.call(:whole, nil) if computed_member_name?(node)
      when Prism::SymbolNode
        member, full = table[node.unescaped.to_sym]
        report.call(:copy, member) if full && !claimed.include?(node)
      end
    end
  end

  def scan_call(node, table, claimed, &report)
    member, full = table[node.name]
    report.call(:read, member) if full
    report.call(:whole, nil) if whole_index?(node)
    (node.arguments&.arguments || []).grep(Prism::SymbolNode).each do |arg|
      kind, member = argument_access(node, arg, table)
      next unless member

      claimed << arg
      report.call(kind, member) if kind
    end
  end

  # How a call treats a member-naming Symbol argument: `[kind, member]`, `[nil, member]` when it names one but does
  # not access it, or nil.
  def argument_access(node, arg, table)
    name = arg.unescaped.to_sym
    member, full = table[name]
    return nil unless member
    return [WRITE_CALLS.include?(node.name) ? :copy : :read, member] if full
    return [nil, member] if AMBIGUOUS_SLOTS.include?(name) && !index_receiver?(node.receiver)
    return [:read, member] if KEY_READ_CALLS.include?(node.name)

    [(WRITE_CALLS.include?(node.name) ? :copy : nil), member]
  end

  # A Symbol list naming two or more slots is an alias list (`%i[def_nodes def_sources]`).
  def scan_alias_list(node, table, claimed, &report)
    slots = node.elements.grep(Prism::SymbolNode).select do |element|
      member, full = table[element.unescaped.to_sym]
      member && !full && !AMBIGUOUS_SLOTS.include?(element.unescaped.to_sym)
    end
    return if slots.size < 2

    slots.each do |element|
      claimed << element
      report.call(:copy, table[element.unescaped.to_sym].first)
    end
  end

  # A slot name held in a constant or variable (`SLOT = :def_nodes`) stands for the slot wherever it is read.
  def scan_slot_holder(node, table)
    held_symbols(node.value).each do |symbol|
      name = symbol.unescaped.to_sym
      member, full = table[name]
      yield :copy, member if member && !full && !AMBIGUOUS_SLOTS.include?(name)
    end
  end

  # The Symbols a held value names: the value itself, a `.freeze` of it, or a list's elements.
  def held_symbols(value)
    case value
    when Prism::SymbolNode then [value]
    when Prism::ArrayNode then value.elements.flat_map { |element| held_symbols(element) }
    when Prism::CallNode then value.name == :freeze && value.receiver ? held_symbols(value.receiver) : []
    else []
    end
  end

  def computed_member_name?(node)
    first = node.parts.first
    first.is_a?(Prism::StringNode) && first.unescaped.start_with?("discovered_")
  end

  # A call that reads or copies every member at once.
  def whole_index?(node)
    first = node.arguments&.arguments&.first
    if node.name == :members
      return !node.receiver.nil? && (index_class?(node.receiver) || discovery_receiver?(node.receiver))
    end
    return false unless discovery_receiver?(node.receiver)
    return !first.nil? && !first.is_a?(Prism::SymbolNode) if SEND_CALLS.include?(node.name)

    WHOLE_INDEX_CALLS.include?(node.name) || (%i[with new].include?(node.name) && splat_argument?(node))
  end

  def splat_argument?(node)
    (node.arguments&.arguments || []).any? do |arg|
      arg.is_a?(Prism::AssocSplatNode) || arg.is_a?(Prism::SplatNode) ||
        (arg.is_a?(Prism::KeywordHashNode) && arg.elements.any?(Prism::AssocSplatNode))
    end
  end

  # A short slot name that is an ordinary word counts only on a receiver named like a discovery table holder.
  def index_receiver?(receiver)
    name = case receiver
           when Prism::CallNode, Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then receiver.name.to_s
           end
    !name.nil? && name.match?(/index|discovery|seed|tables|bundle|summary/)
  end

  def discovery_receiver?(receiver)
    case receiver
    when Prism::CallNode then %i[discovery discovery_index].include?(receiver.name)
    when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then receiver.name.to_s.include?("discovery")
    else index_class?(receiver)
    end
  end

  def index_class?(receiver)
    name = DeclarationFactSources.constant_name(receiver).to_s
    name.end_with?("DiscoveryIndex") || name.end_with?("DiscoveryIndex::EMPTY")
  end
end
