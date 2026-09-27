# frozen_string_literal: true

require "prism"
require "yaml"

# #1507 — the source census the declaration-fact gates share (`spec/rigor/declaration_facts/`). Both gates parse the
# Ruby files under `lib/` and `plugins/*/lib/` with Prism, so a mention in a comment or a string never counts. A
# plugin's specs and demo apps are not producers or readers and are left out.
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

  # The line a failure message ends with, so the person reading it knows how to accept a deliberate change.
  def regenerate_hint(file)
    "If the change is deliberate, rerun with #{REGENERATE_ENV}=1 to rewrite #{file}, then review its diff."
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
end

# WD6's producer tripwire (ADR-119): the methods, and the class or module bodies, whose code decides what a
# declaration is. A scope is a producer when it references `Prism::ClassNode`, `Prism::ModuleNode` or
# `Prism::SingletonClassNode`, one of their node-type symbols, a visibility or mixin keyword as a symbol, or a
# constant this file assigns from any of those. A class whose ancestry includes `DeclarationWalk::Collector` is a
# producer whatever it names.
module DeclarationProducerScan
  NODE_CONSTANTS = %w[Prism::ClassNode Prism::ModuleNode Prism::SingletonClassNode].freeze
  NODE_TYPES = %i[class_node module_node singleton_class_node].freeze
  KEYWORDS = %i[private protected public module_function include extend prepend].freeze
  COLLECTOR = "Rigor::Inference::DeclarationWalk::Collector"

  module_function

  # `{"path#scope" => [reasons]}` over the parsed files.
  def producers(parsed)
    parsed.each_with_object({}) do |(path, root), found|
      tainted = tainted_constants(root)
      scan(root, [], nil, tainted) { |scope, reason| (found["#{path}##{scope}"] ||= []) << reason }
    end.transform_values(&:uniq)
  end

  # The named classes among `classes` whose ancestry includes the declaration walk's collector, as `"path#Class"`
  # keys; with `paths`, only those defined in one of them.
  def collectors(classes = ObjectSpace.each_object(Class), paths: nil)
    collector = Object.const_get(COLLECTOR)
    # Unbound, because a class may redefine `name` or `include?` on itself (an Enumerable class does).
    name_of = Module.instance_method(:name)
    below = Module.instance_method(:<)
    classes.each_with_object({}) do |klass, found|
      name = name_of.bind_call(klass)
      next unless name && below.bind_call(klass, collector)

      file, = Object.const_source_location(name)
      path = file&.delete_prefix("#{DeclarationFactSources::REPO_ROOT}/")
      found["#{path}##{name}"] = ["collector"] if path && (paths.nil? || paths.include?(path))
    end
  end

  # The reason `node` makes its scope a producer, or nil.
  def reason(node, tainted, key_position: false)
    case node
    when Prism::ConstantPathNode, Prism::ConstantReadNode
      name = DeclarationFactSources.constant_name(node)
      return name.delete_prefix("::") if name && NODE_CONSTANTS.include?(name.delete_prefix("::"))
      return "#{node.name} (a constant of this file)" if tainted.include?(node.name)
    when Prism::SymbolNode
      value = node.unescaped.to_sym
      return ":#{value}" if NODE_TYPES.include?(value) || (!key_position && KEYWORDS.include?(value))
    end
    nil
  end

  # The constants this file assigns from a producer reference, directly or through another such constant.
  def tainted_constants(root)
    writes = DeclarationFactSources.each_node(root).filter_map do |node|
      case node
      when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then [node.name, node.value]
      when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode then [node.target.name, node.value]
      end
    end
    tainted = Set.new
    loop do
      grown = writes.reject { |write| tainted.include?(write.first) }.select do |write|
        DeclarationFactSources.each_node(write.last).any? { |node| reason(node, tainted) }
      end
      break if grown.empty?

      tainted.merge(grown.map(&:first))
    end
    tainted
  end

  # Walks `node` under the owner chain `owners`; `scope` is the current method key, nil in a body.
  def scan(node, owners, scope, tainted, &report)
    owners, scope = enter(node, owners, scope)
    if node.is_a?(Prism::AssocNode)
      key_reason = reason(node.key, tainted, key_position: true)
      report.call(scope || body_key(owners), key_reason) if key_reason
      return scan(node.value, owners, scope, tainted, &report) if node.value
    end
    found = reason(node, tainted)
    report.call(scope || body_key(owners), found) if found
    return if node.is_a?(Prism::ConstantPathNode) || node.is_a?(Prism::AssocNode)

    node.compact_child_nodes.each { |child| scan(child, owners, scope, tainted, &report) }
  end

  # The owner chain and method key `node`'s children are scanned under.
  def enter(node, owners, scope)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      [owners + [DeclarationFactSources.constant_name(node.constant_path) || "(dynamic)"], nil]
    when Prism::SingletonClassNode then [owners + ["<<"], nil]
    when Prism::DefNode then [owners, def_key(owners, node)]
    else [owners, scope]
    end
  end

  def body_key(owners)
    owners.empty? ? "(top level)" : owners.join("::").gsub("::<<", " << self")
  end

  def def_key(owners, node)
    singleton = node.receiver || owners.last == "<<"
    owner = owners.reject { |o| o == "<<" }.join("::")
    "#{owner.empty? ? '(top level)' : owner}#{singleton ? '.' : '#'}#{node.name}"
  end
end

# WD1's admission census (ADR-119): per `Scope::DiscoveryIndex` member, the files that read the whole table or copy
# it, outside the table owners. Reads are a call of the member's name, `public_send`/`send` with it, and a key
# (`[:def_sources]`, `fetch(:def_nodes)`, `dig`, `key?`) naming the member or its short slot (the `discovered_`
# prefix stripped; a short slot counts only on a receiver named like an index). Copies are a keyword or hash key
# naming a member, a `[]=` or `store` under one, and a member name elsewhere as a Symbol. A `with(**x)` or `new(**x)`
# on a discovery index, a `send` with a computed name on one, and a `discovered_`-prefixed interpolated Symbol copy
# or read members the code does not name: they are recorded apart, as whole-index copies.
module DiscoveryReadScan
  EXCLUDED = %w[
    lib/rigor/scope.rb lib/rigor/scope/discovery_index.rb lib/rigor/inference/scope_indexer.rb
    lib/rigor/analysis/runner/project_pre_passes.rb
  ].freeze
  READ_CALLS = %i[[] fetch dig key? delete].freeze
  WRITE_CALLS = %i[[]= store].freeze
  SEND_CALLS = %i[public_send send __send__].freeze

  module_function

  # `{alias Symbol => member Symbol}`: each member's own name and its short slot name.
  def aliases(members)
    members.each_with_object({}) do |member, table|
      table[member] = member
      table[member.to_s.delete_prefix("discovered_").to_sym] ||= member
    end
  end

  # `{"members" => {member => {"reads" => [paths], "copies" => [paths]}}, "whole_index_copies" => [paths]}`.
  def census(parsed, members)
    table = aliases(members)
    result = members.to_h { |member| [member.to_s, { "reads" => Set.new, "copies" => Set.new }] }
    whole = Set.new
    column = { read: "reads", copy: "copies" }
    parsed.except(*EXCLUDED).each do |path, root|
      scan(root, table) do |kind, member|
        if kind == :whole
          whole << path
        else
          result[member.to_s][column.fetch(kind)] << path
        end
      end
    end
    { "members" => result.transform_values { |entry| entry.transform_values { |paths| paths.to_a.sort } },
      "whole_index_copies" => whole.to_a.sort }
  end

  def scan(root, table, &report)
    claimed = Set.new.compare_by_identity
    DeclarationFactSources.each_node(root) do |node|
      case node
      when Prism::CallNode then scan_call(node, table, claimed, &report)
      when Prism::AssocNode then scan_key(node.key, table, claimed, &report)
      when Prism::InterpolatedSymbolNode
        report.call(:whole, nil) if node.parts.first.is_a?(Prism::StringNode) &&
                                    node.parts.first.unescaped.start_with?("discovered_")
      when Prism::SymbolNode
        member = table[node.unescaped.to_sym]
        report.call(:copy, member) if member && !claimed.include?(node) && node.unescaped.to_sym == member
      end
    end
  end

  def scan_call(node, table, claimed, &report)
    report.call(:read, node.name) if table[node.name] == node.name
    first = node.arguments&.arguments&.first
    report.call(:whole, nil) if whole_index_copy?(node, first)
    return unless first.is_a?(Prism::SymbolNode)

    name = first.unescaped.to_sym
    member = table[name]
    return unless member

    claimed << first
    return unless member == name || index_receiver?(node.receiver)

    kind = key_access(node.name, member == name)
    report.call(kind, member) if kind
  end

  # Whether a call with a member-naming first argument reads (`[]`, `fetch`, a `send` of the full name) or copies
  # (`[]=`, `store`) the member, or neither.
  def key_access(call_name, full_name)
    return :read if READ_CALLS.include?(call_name) || (SEND_CALLS.include?(call_name) && full_name)

    :copy if WRITE_CALLS.include?(call_name)
  end

  def scan_key(key, table, claimed, &report)
    return unless key.is_a?(Prism::SymbolNode)

    member = table[key.unescaped.to_sym]
    claimed << key
    report.call(:copy, member) if member && member == key.unescaped.to_sym
  end

  # `with(**x)` or `new(**x)` on a discovery index, or `send` with a computed name on one.
  def whole_index_copy?(node, first)
    return false unless discovery_receiver?(node.receiver)
    return !first.nil? && !first.is_a?(Prism::SymbolNode) if SEND_CALLS.include?(node.name)

    %i[with new].include?(node.name) && splat_argument?(node)
  end

  def splat_argument?(node)
    (node.arguments&.arguments || []).any? do |arg|
      arg.is_a?(Prism::AssocSplatNode) ||
        (arg.is_a?(Prism::KeywordHashNode) && arg.elements.any?(Prism::AssocSplatNode))
    end
  end

  # A short slot name (`:methods`, `:classes`) is an ordinary word, so it counts only on a receiver named like a
  # discovery table holder (`index`, `def_index`, `scan_index`, `seed`, `tables`, `bundle`).
  def index_receiver?(receiver)
    name = case receiver
           when Prism::CallNode, Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then receiver.name.to_s
           end
    !name.nil? && name.match?(/index|discovery|seed|tables|bundle/)
  end

  def discovery_receiver?(receiver)
    case receiver
    when Prism::CallNode then %i[discovery discovery_index].include?(receiver.name)
    when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then receiver.name.to_s.include?("discovery")
    when Prism::ConstantPathNode, Prism::ConstantReadNode
      name = DeclarationFactSources.constant_name(receiver).to_s
      name.end_with?("DiscoveryIndex") || name.end_with?("DiscoveryIndex::EMPTY")
    else false
    end
  end
end
