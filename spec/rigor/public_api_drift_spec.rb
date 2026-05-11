# frozen_string_literal: true

require "spec_helper"

# Drift tests for the public API surface ADR-2 § "Public API
# Declaration" expects plugin authors to depend on. The
# `Snapshots` module below pins the public method set for each
# namespace; any addition / removal / arity change has to update
# the snapshot in the same commit. The spec catches accidental
# signature changes before plugin authors notice in the wild.
#
# Snapshot format per method:
#
#   "name(kind1:param1,kind2:param2,...)"
#
# Param `kind` is what `Method#parameters` returns:
# `req` (positional required), `opt` (positional optional),
# `rest` (splat), `key` (keyword), `keyreq` (keyword required),
# `keyrest` (kwsplat), `block` (`&block`).
#
# When you change a public method on purpose, update the matching
# snapshot below in the same commit.
module PublicApiDriftSnapshots # rubocop:disable Metrics/ModuleLength
  SCOPE_INSTANCE = %w[
    ==(req:other)
    class_cvars()
    class_cvars_for(req:class_name)
    class_ivars()
    class_ivars_for(req:class_name)
    cvar(req:name)
    cvars()
    declared_types()
    discovered_classes()
    discovered_def_nodes()
    discovered_method?(req:class_name,req:method_name,req:kind)
    discovered_method_visibilities()
    discovered_method_visibility(req:class_name,req:method_name)
    discovered_methods()
    environment()
    eql?(req:other)
    evaluate(req:node,key:tracer)
    fact_store()
    facts_for(key:target,key:bucket)
    global(req:name)
    globals()
    hash()
    in_source_constants()
    ivar(req:name)
    ivars()
    join(req:other)
    local(req:name)
    local_facts(req:name,key:bucket)
    locals()
    program_globals()
    self_type()
    top_level_def_for(req:method_name)
    type_of(req:node,key:tracer)
    user_def_for(req:class_name,req:method_name)
    with_class_cvars(req:table)
    with_class_ivars(req:table)
    with_cvar(req:name,req:type)
    with_declared_types(req:table)
    with_discovered_classes(req:table)
    with_discovered_def_nodes(req:table)
    with_discovered_method_visibilities(req:table)
    with_discovered_methods(req:table)
    with_fact(req:fact)
    with_global(req:name,req:type)
    with_in_source_constants(req:table)
    with_ivar(req:name,req:type)
    with_local(req:name,req:type)
    with_program_globals(req:table)
    with_self_type(req:type)
  ].freeze

  SCOPE_SINGLETON = %w[empty(key:environment)].freeze

  ENVIRONMENT_INSTANCE = %w[
    class_known?(req:name)
    class_ordering(req:lhs,req:rhs)
    class_registry()
    constant_for_name(req:name)
    dependency_source_index()
    nominal_for_name(req:name)
    plugin_registry()
    rbs_loader()
    singleton_for_name(req:name)
  ].freeze

  ENVIRONMENT_SINGLETON = [
    "default()",
    "for_project(key:root,key:libraries,key:signature_paths,key:cache_store," \
    "key:plugin_registry,key:dependency_source_index)"
  ].freeze

  REFLECTION_SINGLETON = %w[
    class_known?(req:class_name,key:scope)
    class_ordering(req:lhs,req:rhs,key:scope)
    class_type_param_names(req:class_name,key:scope,key:environment)
    constant_type_for(req:constant_name,key:scope)
    discovered_class?(req:class_name,key:scope)
    discovered_method?(req:class_name,req:method_name,key:kind,key:scope)
    instance_definition(req:class_name,key:scope,key:environment)
    instance_method_definition(req:class_name,req:method_name,key:scope,key:environment)
    nominal_for_name(req:class_name,key:scope)
    rbs_class_known?(req:class_name,key:scope,key:environment)
    singleton_definition(req:class_name,key:scope,key:environment)
    singleton_for_name(req:class_name,key:scope)
    singleton_method_definition(req:class_name,req:method_name,key:scope,key:environment)
  ].freeze

  PLUGIN_SINGLETON = %w[
    register(req:plugin_class)
    registered()
    registered_for(req:id)
    unregister!(opt:id)
  ].freeze

  PLUGIN_BASE_INSTANCE = %w[
    cache_for(req:producer_id,key:params,key:descriptor)
    config()
    diagnostics_for_file(keyreq:path,keyreq:scope,keyreq:root)
    flow_contribution_for(keyreq:call_node,keyreq:scope)
    init(req:services)
    io_boundary()
    manifest()
    prepare(req:services)
    services()
  ].freeze

  PLUGIN_BASE_SINGLETON = %w[
    manifest(keyrest:fields)
    producer(req:id,key:serialize,key:deserialize,block:block)
    producers()
  ].freeze

  PLUGIN_MANIFEST_INSTANCE = %w[
    ==(req:other)
    config_schema()
    consumes()
    description()
    eql?(req:other)
    hash()
    id()
    owns_receivers()
    produces()
    protocols()
    to_h()
    validate_config(req:config)
    version()
  ].freeze

  PLUGIN_MANIFEST_CONSUMPTION_INSTANCE = %w[
    name()
    optional()
    plugin_id()
  ].freeze

  PLUGIN_SERVICES_INSTANCE = %w[
    cache_store()
    configuration()
    fact_store()
    io_boundary_for(req:plugin_id)
    reflection()
    trust_policy()
    type()
  ].freeze

  PLUGIN_REGISTRY_INSTANCE = %w[
    any_load_errors?()
    empty?()
    find(req:id)
    ids()
    load_errors()
    plugins()
  ].freeze

  PLUGIN_TRUST_POLICY_INSTANCE = %w[
    allow_read?(req:path)
    allow_url?(req:url)
    allowed_read_roots()
    allowed_url_hosts()
    gem_trusted?(req:name)
    network_allowed?()
    network_policy()
    to_h()
    trusted_gems()
  ].freeze

  PLUGIN_FACT_STORE_INSTANCE = %w[
    each_fact(block:&)
    publish(keyreq:plugin_id,keyreq:name,keyreq:value)
    published?(keyreq:plugin_id,keyreq:name)
    read(keyreq:plugin_id,keyreq:name)
  ].freeze

  PLUGIN_FACT_STORE_FACT_INSTANCE = %w[
    name()
    plugin_id()
    value()
  ].freeze

  PLUGIN_IO_BOUNDARY_INSTANCE = %w[
    cache_descriptor()
    open_url(req:url)
    plugin_id()
    policy()
    read_file(req:path)
  ].freeze

  FLOW_CONTRIBUTION_INSTANCE = %w[
    ==(req:other)
    empty?()
    eql?(req:other)
    exceptional()
    falsey_facts()
    hash()
    invalidations()
    mutations()
    post_return_facts()
    provenance()
    return_type()
    role_conformance()
    to_element_list()
    to_h()
    truthy_facts()
  ].freeze

  FLOW_CONTRIBUTION_MERGE_RESULT_INSTANCE = %w[
    conflict?()
    conflicts()
    empty?()
    exceptional()
    falsey_facts()
    invalidations()
    mutations()
    post_return_facts()
    provenances()
    return_type()
    role_conformance()
    to_h()
    truthy_facts()
  ].freeze

  FLOW_CONTRIBUTION_MERGER_SINGLETON = %w[
    merge(req:contributions)
    tier_for(req:provenance)
  ].freeze

  FLOW_CONTRIBUTION_FACT_INSTANCE = %w[
    negative()
    negative?()
    target()
    target_kind()
    target_name()
    type()
  ].freeze

  TYPE_NODE_IDENTIFIER_INSTANCE = %w[name()].freeze

  TYPE_NODE_GENERIC_INSTANCE = %w[args() head()].freeze

  # Drift-pinned namespaces that still lack a `sig/rigor/*.rbs`
  # entry. Tracked here so the RBS sig drift spec can fail
  # loudly when a sig is added but this list is forgotten —
  # the bookkeeping stays honest and the sig backlog stays
  # visible.
  UNSIGNED_NAMESPACES = %w[
    Rigor::Plugin
    Rigor::Plugin::Base
    Rigor::Plugin::Manifest
    Rigor::Plugin::Services
    Rigor::Plugin::Registry
    Rigor::Plugin::TrustPolicy
    Rigor::Plugin::IoBoundary
    Rigor::Plugin::FactStore
    Rigor::Plugin::FactStore::Fact
    Rigor::Plugin::Manifest::Consumption
    Rigor::FlowContribution
    Rigor::FlowContribution::Fact
    Rigor::FlowContribution::MergeResult
    Rigor::FlowContribution::Merger
    Rigor::TypeNode
    Rigor::TypeNode::Identifier
    Rigor::TypeNode::Generic
  ].freeze

  COMBINATOR_SINGLETON = %w[
    bot()
    constant_of(req:value)
    decimal_int_string()
    difference(req:base,req:removed)
    dynamic(req:static_facet)
    hash_shape_of(opt:pairs,keyrest:options)
    hex_int_string()
    indexed_access(req:type,req:key)
    int_mask(req:flags)
    int_mask_of(req:type)
    integer_range(req:min,req:max)
    intersection(rest:members)
    key_of(req:type)
    literal_string()
    literal_string_carrier?(req:refined)
    literal_string_compatible?(req:type)
    lowercase_string()
    negative_int()
    nominal_of(req:class_name_or_object,key:type_args)
    non_empty_array(opt:element)
    non_empty_hash(opt:key,opt:value)
    non_empty_literal_string()
    non_empty_lowercase_string()
    non_empty_string()
    non_empty_uppercase_string()
    non_lowercase_string()
    non_negative_int()
    non_numeric_string()
    non_positive_int()
    non_uppercase_string()
    non_zero_int()
    numeric_string()
    octal_int_string()
    positive_int()
    refined(req:base,req:predicate_id)
    singleton_of(req:class_name_or_object)
    top()
    tuple_of(rest:elements)
    union(rest:types)
    universal_int()
    untyped()
    uppercase_string()
    value_of(req:type)
  ].freeze
end

RSpec.describe "Public API drift", :public_api_drift do # rubocop:disable RSpec/DescribeClass
  def signature(method)
    params = method.parameters.map { |kind, name| "#{kind}:#{name}" }.join(",")
    "#{method.name}(#{params})"
  end

  def instance_signatures(klass)
    klass.public_instance_methods(false).sort.map { |name| signature(klass.instance_method(name)) }
  end

  def singleton_signatures(klass)
    klass.singleton_methods(false).sort.map { |name| signature(klass.method(name)) }
  end

  describe "Rigor::Scope" do
    it "exposes the expected instance method surface" do
      expect(instance_signatures(Rigor::Scope)).to eq(PublicApiDriftSnapshots::SCOPE_INSTANCE)
    end

    it "exposes the expected class method surface" do
      expect(singleton_signatures(Rigor::Scope)).to eq(PublicApiDriftSnapshots::SCOPE_SINGLETON)
    end
  end

  describe "Rigor::Environment" do
    it "exposes the expected instance method surface" do
      expect(instance_signatures(Rigor::Environment)).to eq(PublicApiDriftSnapshots::ENVIRONMENT_INSTANCE)
    end

    it "exposes the expected class method surface" do
      expect(singleton_signatures(Rigor::Environment)).to eq(PublicApiDriftSnapshots::ENVIRONMENT_SINGLETON)
    end
  end

  describe "Rigor::Type::Combinator" do
    it "exposes the expected factory surface" do
      expect(singleton_signatures(Rigor::Type::Combinator)).to eq(PublicApiDriftSnapshots::COMBINATOR_SINGLETON)
    end
  end

  describe "Rigor::Reflection" do
    it "exposes the expected read-side facade surface" do
      expect(singleton_signatures(Rigor::Reflection)).to eq(PublicApiDriftSnapshots::REFLECTION_SINGLETON)
    end
  end

  describe "Rigor::Plugin" do
    it "exposes the expected registration surface" do
      expect(singleton_signatures(Rigor::Plugin)).to eq(PublicApiDriftSnapshots::PLUGIN_SINGLETON)
    end
  end

  describe "Rigor::Plugin::Base" do
    it "exposes the expected instance surface" do
      expect(instance_signatures(Rigor::Plugin::Base)).to eq(PublicApiDriftSnapshots::PLUGIN_BASE_INSTANCE)
    end

    it "exposes the expected class surface" do
      expect(singleton_signatures(Rigor::Plugin::Base)).to eq(PublicApiDriftSnapshots::PLUGIN_BASE_SINGLETON)
    end
  end

  describe "Rigor::Plugin::Manifest" do
    it "exposes the expected value-object surface" do
      expect(instance_signatures(Rigor::Plugin::Manifest)).to eq(PublicApiDriftSnapshots::PLUGIN_MANIFEST_INSTANCE)
    end
  end

  describe "Rigor::Plugin::Services" do
    it "exposes the expected DI accessor surface" do
      expect(instance_signatures(Rigor::Plugin::Services)).to eq(PublicApiDriftSnapshots::PLUGIN_SERVICES_INSTANCE)
    end
  end

  describe "Rigor::Plugin::Registry" do
    it "exposes the expected read-side surface" do
      expect(instance_signatures(Rigor::Plugin::Registry)).to eq(PublicApiDriftSnapshots::PLUGIN_REGISTRY_INSTANCE)
    end
  end

  describe "Rigor::Plugin::TrustPolicy" do
    it "exposes the expected policy surface" do
      expect(instance_signatures(Rigor::Plugin::TrustPolicy)).to eq(
        PublicApiDriftSnapshots::PLUGIN_TRUST_POLICY_INSTANCE
      )
    end
  end

  describe "Rigor::Plugin::IoBoundary" do
    it "exposes the expected I/O surface" do
      expect(instance_signatures(Rigor::Plugin::IoBoundary)).to eq(
        PublicApiDriftSnapshots::PLUGIN_IO_BOUNDARY_INSTANCE
      )
    end
  end

  describe "Rigor::FlowContribution" do
    it "exposes the expected bundle surface" do
      expect(instance_signatures(Rigor::FlowContribution)).to eq(
        PublicApiDriftSnapshots::FLOW_CONTRIBUTION_INSTANCE
      )
    end
  end

  describe "Rigor::FlowContribution::MergeResult" do
    it "exposes the expected merge-result surface" do
      expect(instance_signatures(Rigor::FlowContribution::MergeResult)).to eq(
        PublicApiDriftSnapshots::FLOW_CONTRIBUTION_MERGE_RESULT_INSTANCE
      )
    end
  end

  describe "Rigor::FlowContribution::Merger" do
    it "exposes the expected merger entry-point surface" do
      expect(singleton_signatures(Rigor::FlowContribution::Merger)).to eq(
        PublicApiDriftSnapshots::FLOW_CONTRIBUTION_MERGER_SINGLETON
      )
    end
  end

  describe "Rigor::FlowContribution::Fact" do
    it "exposes the expected canonical-fact surface" do
      expect(instance_signatures(Rigor::FlowContribution::Fact)).to eq(
        PublicApiDriftSnapshots::FLOW_CONTRIBUTION_FACT_INSTANCE
      )
    end
  end

  describe "Rigor::Plugin::FactStore" do
    it "exposes the expected publish / read / iterate surface" do
      expect(instance_signatures(Rigor::Plugin::FactStore)).to eq(
        PublicApiDriftSnapshots::PLUGIN_FACT_STORE_INSTANCE
      )
    end
  end

  describe "Rigor::Plugin::FactStore::Fact" do
    it "exposes the expected (plugin_id, name, value) data shape" do
      expect(instance_signatures(Rigor::Plugin::FactStore::Fact)).to eq(
        PublicApiDriftSnapshots::PLUGIN_FACT_STORE_FACT_INSTANCE
      )
    end
  end

  describe "Rigor::Plugin::Manifest::Consumption" do
    it "exposes the expected (plugin_id, name, optional) data shape" do
      expect(instance_signatures(Rigor::Plugin::Manifest::Consumption)).to eq(
        PublicApiDriftSnapshots::PLUGIN_MANIFEST_CONSUMPTION_INSTANCE
      )
    end
  end

  describe "Rigor::TypeNode::Identifier" do
    it "exposes the expected ADR-13 slice-1 named-type carrier surface" do
      expect(instance_signatures(Rigor::TypeNode::Identifier)).to eq(
        PublicApiDriftSnapshots::TYPE_NODE_IDENTIFIER_INSTANCE
      )
    end
  end

  describe "Rigor::TypeNode::Generic" do
    it "exposes the expected ADR-13 slice-1 generic-type carrier surface" do
      expect(instance_signatures(Rigor::TypeNode::Generic)).to eq(
        PublicApiDriftSnapshots::TYPE_NODE_GENERIC_INSTANCE
      )
    end
  end

  # RBS sig drift detection. The runtime drift snapshots above
  # catch accidental changes to the public Ruby API; this block
  # catches the dual: when a public Ruby method is added to a
  # drift-pinned namespace but the matching `sig/rigor/*.rbs`
  # entry is forgotten. The v0.0.9 cache regression hid for
  # months because every runtime addition since v0.0.9 had drifted
  # away from the RBS sigs without any check; landing this spec
  # ensures the same gap cannot reopen silently.
  #
  # Skips namespaces that have no RBS sig at all (yet) — those
  # are deliberate gaps tracked in the broader sig-coverage
  # backlog (lib/rigor/plugin/, lib/rigor/flow_contribution/,
  # lib/rigor/cache/, lib/rigor/analysis/, …).
  describe "RBS sig drift" do
    def sig_env
      @sig_env ||= begin
        require "rbs"
        loader = RBS::EnvironmentLoader.new
        loader.add(path: Pathname("sig"))
        RBS::Environment.from_loader(loader).resolve_type_names
      end
    end

    def sig_method_kinds_for(class_name)
      rbs_name = RBS::TypeName.parse("::#{class_name}")
      entry = sig_env.class_decls[rbs_name] || sig_env.class_alias_decls[rbs_name]
      return nil if entry.nil?

      instance = []
      singleton = []
      entry.each_decl do |decl|
        decl.members.each { |member| collect_method_member(member, instance, singleton) }
      end
      { instance: instance, singleton: singleton }
    end

    # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
    def collect_method_member(member, instance, singleton)
      case member
      when RBS::AST::Members::MethodDefinition
        case member.kind
        when :instance then instance << member.name.to_s
        when :singleton then singleton << member.name.to_s
        when :singleton_instance
          instance << member.name.to_s
          singleton << member.name.to_s
        end
      when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrWriter, RBS::AST::Members::AttrAccessor
        # `attr_reader name: T` declares an instance reader
        # (and writer for AttrAccessor / AttrWriter).
        instance << member.name.to_s
        if member.is_a?(RBS::AST::Members::AttrAccessor) || member.is_a?(RBS::AST::Members::AttrWriter)
          instance << "#{member.name}="
        end
      when RBS::AST::Members::Alias
        # `alias eql? ==` declares an alias. Both target and
        # new name resolve at runtime to the same method.
        bucket = member.kind == :singleton ? singleton : instance
        bucket << member.new_name.to_s
      end
    end
    # rubocop:enable Metrics/AbcSize,Metrics/CyclomaticComplexity

    def names_from_snapshot(snapshot)
      snapshot.map { |s| s.split("(").first }
    end

    def expect_sig_covers(class_name:, kind:, snapshot:)
      sig_methods = sig_method_kinds_for(class_name)
      expect(sig_methods).not_to(
        be_nil,
        "expected sig/rigor/*.rbs to declare #{class_name.inspect}, but no decl was found"
      )
      runtime = names_from_snapshot(snapshot)
      missing = runtime - sig_methods.fetch(kind)
      expect(missing).to(
        be_empty,
        "RBS sig for #{class_name} missing #{kind} methods: #{missing.inspect}"
      )
    end

    it "covers Rigor::Scope instance methods" do
      expect_sig_covers(class_name: "Rigor::Scope", kind: :instance,
                        snapshot: PublicApiDriftSnapshots::SCOPE_INSTANCE)
    end

    it "covers Rigor::Scope singleton methods" do
      expect_sig_covers(class_name: "Rigor::Scope", kind: :singleton,
                        snapshot: PublicApiDriftSnapshots::SCOPE_SINGLETON)
    end

    it "covers Rigor::Environment instance methods" do
      expect_sig_covers(class_name: "Rigor::Environment", kind: :instance,
                        snapshot: PublicApiDriftSnapshots::ENVIRONMENT_INSTANCE)
    end

    it "covers Rigor::Environment singleton methods" do
      expect_sig_covers(class_name: "Rigor::Environment", kind: :singleton,
                        snapshot: PublicApiDriftSnapshots::ENVIRONMENT_SINGLETON)
    end

    it "covers Rigor::Type::Combinator singleton methods" do
      expect_sig_covers(class_name: "Rigor::Type::Combinator", kind: :singleton,
                        snapshot: PublicApiDriftSnapshots::COMBINATOR_SINGLETON)
    end

    it "covers Rigor::Reflection singleton methods" do
      expect_sig_covers(class_name: "Rigor::Reflection", kind: :singleton,
                        snapshot: PublicApiDriftSnapshots::REFLECTION_SINGLETON)
    end

    # Namespaces without an RBS sig today — recorded so the
    # absence is visible in test output, not silent. Adding a
    # sig file removes the corresponding entry from this list.
    it "lists drift-pinned namespaces that still lack an RBS sig" do
      unsigned = PublicApiDriftSnapshots::UNSIGNED_NAMESPACES
      missing_sig = unsigned.reject { |name| sig_method_kinds_for(name) }
      # Allow the list to be either fully missing (current state)
      # or fully signed (someone added all sigs at once). A
      # partial state means a sig was added but the list wasn't
      # updated — fail so the bookkeeping stays honest.
      next if missing_sig.empty?

      expect(missing_sig).to eq(unsigned)
    end
  end
end
