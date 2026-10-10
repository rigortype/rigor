# frozen_string_literal: true

# #1507 — the structural check behind each `DiscoveryIndex::MEMBER_CLASSES` class (ADR-119 WD4), applied to the two
# indexes {DeclarationFactFixture} builds. `problems(classes, fixture)` returns one line per member whose value does
# not have its class's shape.
#
# - Set-valued: a Hash or Set whose keys are names and whose entries are collections of names, rows or kind flags;
#   no entry is a bare value, a `path:line` site or a visibility, which only single-valued tables hold.
#   `discovered_classes` is the exception its reason names: each value is its own name's singleton.
# - Single-valued: every slot holds the one kind of value the member's entry in {SLOT_KINDS} records, unwrapped.
# - Typed: every leaf is a `Rigor::Type`, and the values are not merely each key's own singleton.
# - Syntactic: read off the analysed file alone, so the file's parse without the project seed gives the same value.
# - Run state: an opaque token the runner's seed supplies, which neither the file's parse alone nor a persisted seed
#   bundle carries.
#
# - Sibling (ADR-119 WD1): the `possible_*` / `contested_*` half of a `DiscoveryIndex::SIBLINGS` pair. `possible_*` has
#   its member's shape and every entry is in the member; `contested_*` is a Set of key paths that resolve in the
#   member. No producer fills one yet, so on the fixture the check is vacuous and {sibling_problem} is exercised
#   directly with injected values.
#
# `implicit_self_evidence`, `in_effect_refinements` and `toplevel_statement_calls` must also never ride a seed: each
# holds its own file's parse.
module DeclarationMemberShapes
  SCALARS = [String, Symbol, Integer, NilClass, TrueClass, FalseClass].freeze
  VISIBILITIES = %i[public private protected].freeze
  SITE = /:\d+\z/
  TABLES_AND_FACTS = [Hash, Set, Array, TrueClass, FalseClass].freeze
  # The syntactic members whose value is a lazy per-file query over the file's tree rather than a table.
  PER_FILE_QUERIES = {
    implicit_self_evidence: Rigor::Inference::LastLine::SelfEvidence,
    in_effect_refinements: Rigor::Inference::InEffectRefinements,
    toplevel_statement_calls: Rigor::Inference::ToplevelStatementCalls
  }.freeze
  # The two members the fixture cannot fill, and why.
  UNFILLED = {
    param_inferred_types: "only `coverage --protection`'s collection pass fills it"
  }.freeze

  module_function

  def problems(classes, fixture)
    classes.flat_map do |klass, entries|
      entries.keys.filter_map do |member|
        value = fixture.fetch(:discovery).first.public_send(member)
        next sibling_line(member, value, fixture) if klass == :sibling
        next "#{member}: empty in the fixture" if empty?(value) && !UNFILLED.key?(member)
        next if UNFILLED.key?(member)

        why = shape_problem(klass, member, value, fixture)
        "#{member} (#{klass}): #{why}" if why
      end
    end
  end

  def sibling_line(member, value, fixture)
    why = sibling_problem(member, value, fixture.fetch(:discovery).first)
    "#{member} (sibling): #{why}" if why
  end

  # The shape problem of a sibling's `value` against its member's value in `index`, or nil.
  def sibling_problem(sibling, value, index)
    member = Rigor::Scope::DiscoveryIndex::SIBLINGS.key(sibling)
    return "not a sibling of any member" if member.nil?

    member_value = index.public_send(member)
    return contested_problem(value, member_value) if sibling.start_with?("contested_")

    possible_problem(value, member_value)
  end

  def contested_problem(value, member_value)
    return "not a Set" unless value.is_a?(Set)
    return "a key path is not an Array" unless value.all?(Array)

    "a key path does not resolve in the member" unless value.all? { |path| resolves?(member_value, path) }
  end

  def resolves?(table, path)
    path.all? do |key|
      next false unless table.is_a?(Hash) && table.key?(key)

      table = table.fetch(key)
      true
    end
  end

  def possible_problem(value, member_value)
    return "not the member's kind of table" unless value.is_a?(member_value.class.ancestors.find do |k|
      [Hash, Set].include?(k)
    end)

    "an entry is not in the member" unless subset?(value, member_value)
  end

  # Every key of `value`, at any depth, is in `whole`; a leaf must be the same or a part of it (`:both`).
  def subset?(value, whole)
    case value
    when Hash then whole.is_a?(Hash) && value.all? { |key, entry| whole.key?(key) && subset?(entry, whole.fetch(key)) }
    when Set, Array then value.all? { |entry| whole.include?(entry) }
    else value == whole || whole == Rigor::Scope::DiscoveryIndex::METHOD_KIND_BOTH
    end
  end

  def empty?(value)
    value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?)
  end

  def shape_problem(klass, member, value, fixture)
    case klass
    when :set_valued then set_valued_problem(member, value)
    when :single_valued then single_valued_problem(member, value)
    when :typed then typed_problem(value)
    when :syntactic then syntactic_problem(member, value, fixture)
    when :run_state then run_state_problem(member, value, fixture)
    end
  end

  def set_valued_problem(member, value)
    if member == :discovered_classes
      return own_singletons?(value) ? nil : "a value is not the singleton of its own name"
    end
    return "not a Hash or Set" unless value.is_a?(Hash) || value.is_a?(Set)
    return "an entry is a bare value, not a collection" if value.is_a?(Hash) && value.values.any? { |v| scalar?(v) }
    return "a key is not a name" unless names_as_keys?(value)

    "holds something other than names, rows or kind flags" unless set_leaves?(value)
  end

  def own_singletons?(value)
    value.is_a?(Hash) &&
      value.all? { |name, type| type.is_a?(Rigor::Type::Singleton) && type.class_name == name }
  end

  def scalar?(value)
    SCALARS.any? { |scalar| value.is_a?(scalar) }
  end

  # Every Hash key, at any depth, is a String or Symbol name.
  def names_as_keys?(value)
    case value
    when Hash then value.all? { |key, entry| (key.is_a?(String) || key.is_a?(Symbol)) && names_as_keys?(entry) }
    when Set, Array then value.all? { |entry| names_as_keys?(entry) }
    else true
    end
  end

  def set_leaves?(value)
    case value
    when Hash then value.values.all? { |entry| set_leaves?(entry) }
    when Set, Array then value.all? { |entry| set_leaves?(entry) }
    when String then !value.match?(SITE)
    when Symbol then !VISIBILITIES.include?(value)
    else scalar?(value)
    end
  end

  # The one value each slot holds today, unwrapped: a def node or handle, a site, a visibility, an envelope, a name,
  # a chain or an alternatives list, a layout.
  SLOT_KINDS = {
    discovered_def_nodes: ->(slot) { slot.is_a?(Prism::DefNode) || slot.is_a?(Rigor::Inference::DefHandle) },
    discovered_singleton_def_nodes: ->(slot) { slot.is_a?(Prism::DefNode) || slot.is_a?(Rigor::Inference::DefHandle) },
    discovered_def_sources: ->(slot) { slot.is_a?(String) && slot.match?(SITE) },
    discovered_singleton_def_sources: ->(slot) { slot.is_a?(String) && slot.match?(SITE) },
    discovered_method_visibilities: ->(slot) { VISIBILITIES.include?(slot) },
    discovered_parameter_envelopes: lambda do |slot|
      slot == Rigor::Source::ParameterEnvelope::OPAQUE || (slot.is_a?(Array) && slot.size == 3)
    end,
    discovered_superclasses: ->(slot) { slot.is_a?(String) },
    discovered_header_nestings: lambda do |slot|
      slot.is_a?(Array) && (slot.all?(String) || slot.all? { |chain| chain.is_a?(Array) && chain.all?(String) })
    end,
    data_member_layouts: ->(slot) { slot.is_a?(Array) && slot.all?(Symbol) },
    struct_member_layouts: ->(slot) { slot.is_a?(Hash) && slot[:members].is_a?(Array) }
  }.freeze
  # The members whose slots sit one level down, under a method name or an ancestor name.
  NESTED_SLOTS = %i[
    discovered_def_nodes discovered_singleton_def_nodes discovered_def_sources discovered_singleton_def_sources
    discovered_method_visibilities discovered_parameter_envelopes discovered_header_nestings
  ].freeze

  def single_valued_problem(member, value)
    kind = SLOT_KINDS[member]
    return "no slot kind is recorded for it" unless kind
    return "not a Hash" unless value.is_a?(Hash)

    "a slot holds something other than its kind" unless slots_of(member, value).all? { |slot| kind.call(slot) }
  end

  # The slots of a single-valued table: its values, or one level down for the per-method and per-ancestor tables.
  def slots_of(member, value)
    return value.values unless NESTED_SLOTS.include?(member)

    value.values.flat_map { |table| table.is_a?(Hash) ? table.values : [nil] }
  end

  def typed_problem(value)
    return "not a Hash" unless value.is_a?(Hash)
    return "the values are only each name's own singleton" if own_singletons?(value)

    "a leaf is not a Rigor::Type" unless typed_tree?(value)
  end

  def typed_tree?(value)
    value.is_a?(Hash) ? value.values.all? { |entry| typed_tree?(entry) } : value.class.name.to_s.start_with?("Rigor::Type::")
  end

  def syntactic_problem(member, value, fixture)
    file_only, file_root = fixture.fetch(:file_only)
    alone = file_only.public_send(member)
    case member
    when :discovered_def_nestings
      root = fixture.fetch(:discovery).last
      "the file's parse alone gives other nestings" unless nestings(value, root) == nestings(alone, file_root)
    when :implicit_self_evidence, :in_effect_refinements, :toplevel_statement_calls
      klass = PER_FILE_QUERIES.fetch(member)
      return "not a #{klass.name}" unless value.is_a?(klass)
      return "the file's parse alone gives none" unless alone.is_a?(klass)

      "it rides a seed" if in_runner_seed?(member, fixture) || in_bundles?(member, fixture)
    else
      "the file's parse alone gives #{brief(alone)}, not #{brief(value)}" unless value == alone
    end
  end

  def brief(value)
    text = value.inspect
    text.size > 60 ? "#{text[0, 57]}..." : text
  end

  # Def nestings keyed by each def's position, so two parses of one file compare.
  def nestings(table, root)
    DeclarationFactSources.each_node(root).grep(Prism::DefNode).to_h { |node| [node.location.start_offset, table[node]] }
  end

  def run_state_problem(member, value, fixture)
    return "a table or a fact, not an opaque token" if TABLES_AND_FACTS.any? { |kind| value.is_a?(kind) }
    return "a type, not an opaque token" if value.class.name.to_s.start_with?("Rigor::Type::")
    return "the file's parse alone carries it" unless fixture.fetch(:file_only).first.public_send(member).nil?
    return "the runner's seed does not carry it" unless in_runner_seed?(member, fixture)

    "it is persisted in a seed bundle" if in_bundles?(member, fixture)
  end

  def in_runner_seed?(member, fixture)
    fixture.fetch(:seed).key?(member)
  end

  # Whether an ADR-85 per-file seed bundle carries the member, under its own name or its short slot.
  def in_bundles?(member, fixture)
    short = member.to_s.delete_prefix("discovered_").to_sym
    fixture.fetch(:bundles).values.any? { |bundle| bundle.key?(member) || bundle.key?(short) }
  end

  # `{member => [classes it passes as, other than its own]}` for every member: the misfilings the checks accept.
  def accepted_misfilings(classes, fixture)
    classes.each_with_object({}) do |(own, entries), accepted|
      entries.each_key do |member|
        next if UNFILLED.key?(member) || own == :sibling

        passes = (classes.keys - [own]).select do |other|
          problems(refiled(classes, member, other), fixture).none? { |line| line.start_with?("#{member} ") }
        end
        accepted[member] = passes unless passes.empty?
      end
    end
  end

  # `classes` with `member` taken out of its class and filed under `klass`.
  def refiled(classes, member, klass)
    classes.to_h { |name, entries| [name, entries.except(member)] }
           .tap { |copy| copy[klass] = copy[klass].merge(member => "refiled") }
  end
end
