# frozen_string_literal: true

# #1507 — the structural check behind each `DiscoveryIndex::MEMBER_CLASSES` class (ADR-119 WD4), applied to the index
# {DeclarationFactFixture} builds. `problems(classes, fixture)` returns one line per member whose value does not have
# its class's shape, so a member filed under the wrong class fails, not only a missing one.
module DeclarationMemberShapes
  SCALARS = [String, Symbol, Integer, NilClass, TrueClass, FalseClass].freeze
  VISIBILITIES = %i[public private protected].freeze
  # The two members the fixture cannot fill, and why.
  UNFILLED = {
    param_inferred_types: "only `coverage --protection`'s collection pass fills it",
    run_generation: "`Runner#run_analysis` mints it once per run; the fixture builds the index without a run"
  }.freeze

  module_function

  def problems(classes, fixture)
    discovery, root = fixture.fetch(:discovery)
    second, second_root = fixture.fetch(:second)
    classes.flat_map do |klass, entries|
      entries.keys.filter_map do |member|
        value = discovery.public_send(member)
        next "#{member}: empty in the fixture" if empty?(value) && !UNFILLED.key?(member)

        why = shape_problem(klass, member, value, second.public_send(member), [root, second_root], fixture)
        "#{member} (#{klass}): #{why}" if why
      end
    end
  end

  def empty?(value)
    value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?)
  end

  def shape_problem(klass, member, value, again, roots, fixture)
    case klass
    when :set_valued then set_valued_problem(member, value)
    when :single_valued then single_valued_problem(member, value)
    when :typed then typed_problem(value)
    when :syntactic then syntactic_problem(member, value, again, roots, fixture)
    when :run_state then run_state_problem(member, value, fixture)
    end
  end

  # Names, edges, files or rows: containers of scalars. `discovered_classes` keeps each name's singleton beside it.
  def set_valued_problem(member, value)
    if member == :discovered_classes
      own_singletons = value.is_a?(Hash) &&
                       value.all? { |name, type| type.is_a?(Rigor::Type::Singleton) && type.class_name == name }
      return own_singletons ? nil : "a value is not the singleton of its own name"
    end
    return "not a Hash or Set" unless value.is_a?(Hash) || value.is_a?(Set)

    "holds something other than names, rows or flags" unless scalar_tree?(value)
  end

  def scalar_tree?(value)
    case value
    when Hash then value.all? { |key, entry| scalar_tree?(key) && scalar_tree?(entry) }
    when Set, Array then value.all? { |entry| scalar_tree?(entry) }
    else SCALARS.any? { |scalar| value.is_a?(scalar) }
    end
  end

  # The one value each slot holds today, unwrapped: a def node or handle, a site, a visibility, an envelope, a name,
  # a chain or an alternatives list, a layout.
  SLOT_KINDS = {
    discovered_def_nodes: ->(slot) { slot.is_a?(Prism::DefNode) || slot.is_a?(Rigor::Inference::DefHandle) },
    discovered_singleton_def_nodes: ->(slot) { slot.is_a?(Prism::DefNode) || slot.is_a?(Rigor::Inference::DefHandle) },
    discovered_def_sources: ->(slot) { slot.is_a?(String) && slot.match?(/:\d+\z/) },
    discovered_singleton_def_sources: ->(slot) { slot.is_a?(String) && slot.match?(/:\d+\z/) },
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

    "a leaf is not a Rigor::Type" unless typed_tree?(value)
  end

  def typed_tree?(value)
    value.is_a?(Hash) ? value.values.all? { |entry| typed_tree?(entry) } : value.class.name.to_s.start_with?("Rigor::Type::")
  end

  # Read off the analysed file alone, so a second, independent parse gives the same answer. The implicit-self
  # evidence is a lazy object over the parse, so it is compared by kind, and it must never ride a seed: another
  # file's readers would find their own parse missing from it.
  def syntactic_problem(member, value, again, roots, fixture)
    case member
    when :discovered_def_nestings
      "a second parse records different nestings" unless nestings(value, roots.first) == nestings(again, roots.last)
    when :implicit_self_evidence
      return "not a LastLine::SelfEvidence" unless value.is_a?(Rigor::Inference::LastLine::SelfEvidence)

      "it rides a seed" if in_runner_seed?(member, fixture) || in_bundles?(member, fixture)
    else
      "a second parse gives #{again.inspect}, not #{value.inspect}" unless value == again
    end
  end

  def nestings(table, root)
    DeclarationFactSources.each_node(root).grep(Prism::DefNode).to_h { |node| [node.location.start_offset, table[node]] }
  end

  # Run state may ride the in-memory seed of the run it belongs to, never a persisted per-file bundle.
  def run_state_problem(member, _value, fixture)
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
end
