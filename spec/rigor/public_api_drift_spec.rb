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
    nominal_for_name(req:name)
    rbs_loader()
    singleton_for_name(req:name)
  ].freeze

  ENVIRONMENT_SINGLETON = %w[
    default()
    for_project(key:root,key:libraries,key:signature_paths,key:cache_store)
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
    config()
    init(req:services)
    manifest()
    services()
  ].freeze

  PLUGIN_BASE_SINGLETON = %w[manifest(keyrest:fields)].freeze

  PLUGIN_MANIFEST_INSTANCE = %w[
    ==(req:other)
    config_schema()
    description()
    eql?(req:other)
    hash()
    id()
    protocols()
    to_h()
    validate_config(req:config)
    version()
  ].freeze

  PLUGIN_SERVICES_INSTANCE = %w[
    cache_store()
    configuration()
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
    allowed_read_roots()
    gem_trusted?(req:name)
    network_allowed?()
    network_policy()
    to_h()
    trusted_gems()
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
end
