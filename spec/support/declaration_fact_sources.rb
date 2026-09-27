# frozen_string_literal: true

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

  def write_yaml(path, header, data)
    File.write(path, header + YAML.dump(data, line_width: -1).delete_prefix("---\n"))
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
# - (v) in `scope_indexer.rb`, is reachable through same-file calls from one of `DeclarationWriterScan::ROOTS` and
#   writes into one of its parameters, a `*rest` or `**rest` included: an indexed assignment or a `<<` /
#   `merge!` / `add?`-style call into it, or passing it (by position, keyword or splat) to a same-file method that
#   does.
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
  RULE_V_FILE = "lib/rigor/inference/scope_indexer.rb"
  DEFINE_METHOD_CALLS = %i[define_method define_singleton_method].freeze

  module_function

  # `{"path#scope" => [reasons]}` over the parsed files.
  def producers(parsed)
    tainted = tainted_constants(parsed)
    found = Hash.new { |table, key| table[key] = [] }
    parsed.each do |path, root|
      skipped = catalogue_symbols(root)
      scan(root, [], nil, tainted, skipped) { |scope, reason| found["#{path}##{scope}"] << reason }
    end
    collectors(parsed) { |path, scope, why| found["#{path}##{scope}"] << why }
    DeclarationWriterScan.rule_v(parsed.fetch(RULE_V_FILE, nil)) do |scope|
      found["#{RULE_V_FILE}##{scope}"] << "writes a table (rule v)"
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

# ADR-119 WD6's rule (v): the methods of `scope_indexer.rb` that are reachable from `ROOTS` through same-file calls
# and write into one of their parameters: an indexed assignment or a `<<` / `merge!`-style call into it, or passing
# it to a same-file method that does.
module DeclarationWriterScan
  WRITE_CALLS = %i[[]= << push unshift concat merge! store add add? update].freeze
  # ADR-119's three roots, then the multi-file entry points: their folds (`finalize_project_index`,
  # `fold_def_tables`, `fold_def_sources`, …) are reachable from no other root.
  ROOTS = %i[
    index accumulate_project_index finalize_def_index
    discovered_classes_for_paths discovered_def_index_for_paths discovered_project_index_for_paths
    discovered_project_index_incremental
  ].freeze

  module_function

  # Rule (v): yields the keys of `scope_indexer.rb`'s methods that are reachable from its entry points and write
  # into a parameter.
  def rule_v(root)
    return unless root

    # Every definition of a name counts: a reopening or a `def self.x` beside a `module_function` copy.
    defs = Hash.new { |table, name| table[name] = [] }
    DeclarationFactSources.each_with_owners(root) do |node, owners|
      defs[node.name] << [node, owners] if node.is_a?(Prism::DefNode)
    end
    calls = defs.transform_values { |sites| sites.flat_map { |node, _| same_file_calls(node, defs) } }
    writers = parameter_writers(defs, calls)
    reachable(calls).each do |name|
      next if writers.fetch(name).empty?

      defs.fetch(name).each { |node, owners| yield DeclarationProducerScan.def_key(owners, node, node.receiver) }
    end
  end

  def same_file_calls(def_node, defs)
    DeclarationFactSources.each_node(def_node.body || def_node).select do |node|
      node.is_a?(Prism::CallNode) && defs.key?(node.name) && self_receiver?(node.receiver)
    end
  end

  def self_receiver?(receiver)
    receiver.nil? || receiver.is_a?(Prism::SelfNode) ||
      DeclarationFactSources.constant_name(receiver).to_s.end_with?("ScopeIndexer")
  end

  def reachable(calls)
    seen = Set.new
    pending = ROOTS.select { |root| calls.key?(root) }
    until pending.empty?
      name = pending.pop
      next unless seen.add?(name)

      pending.concat(calls.fetch(name).map(&:name))
    end
    seen
  end

  # `{method name => Set[parameter names it writes]}`, directly or by passing one to a same-file writer.
  def parameter_writers(defs, calls)
    params = defs.transform_values { |sites| sites.flat_map { |node, _| parameter_names(node) }.uniq }
    writes = defs.to_h do |name, sites|
      [name, sites.map { |node, _| direct_writes(node, params.fetch(name)) }.reduce(Set.new, :|)]
    end
    loop do
      grown = false
      calls.each do |name, sites|
        sites.each do |site|
          passed_writes(site, defs.fetch(site.name), params, writes).each do |param|
            next unless params.fetch(name).include?(param) && writes[name].add?(param)

            grown = true
          end
        end
      end
      return writes unless grown
    end
  end

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
    DeclarationFactSources.each_node(def_node.body || def_node) do |node|
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

  # The caller's parameters a same-file call hands to a parameter the callee writes: by position or keyword, into a
  # `*rest` or `**rest` that absorbs the argument, or as a `*splat` / `**splat`.
  def passed_writes(site, callee_sites, params, writes)
    callee_writes = writes.fetch(site.name)
    caller_params = params.values.flatten
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
#   (`SLOT = :def_nodes`), which stands for the slot wherever it is read.
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
      when Prism::ConstantWriteNode, Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode
        scan_slot_holder(node, table, &report)
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
    return unless node.value.is_a?(Prism::SymbolNode)

    name = node.value.unescaped.to_sym
    member, full = table[name]
    yield :copy, member if member && !full && !AMBIGUOUS_SLOTS.include?(name)
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
