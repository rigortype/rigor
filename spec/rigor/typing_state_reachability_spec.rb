# frozen_string_literal: true

require "spec_helper"

require "rigor/analysis/runner"
require "rigor/configuration"

# ADR-129 G4 — the reachability audit. While Rigor analyses the integration fixtures, every {#stride}th
# `ExpressionTyper#type_of` call is sampled: the walker ({TypingStateReachability::Walker}) follows everything
# reachable from that call's scope, `scope.environment` included, and from the slot values of the thread's
# TypingState, and reports each mutable object that is not frozen, a Prism node, a slot's storage, a bound Table's
# store or a declared Memo ({Rigor::TypingState.memo_field}, a Memo slot, a Frame's `memos:`).
#
# The findings no declaration accounts for are listed in {#allow_list}, one row per field with the classes found there
# and why the field is not yet a slot or a Memo. A field that is not listed, a class a row does not name, and a row or
# class no longer found all fail: the list only shrinks, and growing it needs a reason a reviewer accepts.
RSpec.describe "ADR-129 G4: what a type_of call can reach" do
  # Every top-level `.rb` fixture, analysed in one sequential run with no cache. The stride keeps the walk to about
  # 1,200 samples.
  def stride = 50

  def fixture_paths = Dir.glob("spec/integration/fixtures/*.rb")

  def sample_fixtures
    walker = TypingStateReachability::Walker.new
    calls = 0
    trace = TracePoint.new(:call) do |point|
      calls += 1
      next unless (calls % stride).zero?

      walker.sample(point.self.instance_variable_get(:@scope), Rigor::TypingState.current)
    end
    paths = fixture_paths
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => paths, "workers" => 0))
    trace.enable(target: Rigor::Inference::ExpressionTyper.instance_method(:type_of)) do
      guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), paths)
    end
    walker
  end

  # `field => [classes, reason]`. `reassigned` names a field of a memo holder that took a new object between samples.
  def allow_list = environment_rows.merge(discovery_rows, scope_rows, slot_rows)

  def environment_rows # rubocop:disable Metrics/MethodLength
    input = "a construction input the environment or loader is built with and never mutates, not frozen deeply"
    sink = "an output sink typing appends to and the run drains after analysis; typing never reads it back (a " \
           "Resource-shaped output, ADR-129 WD5 and #2814), not yet a slot"
    holder = "Environment::Reporters is the mutable box long-lived integrations swap reporters in per run"
    {
      'Rigor::Environment#@missing_rbs_bundle_path' => [%w[String], input],
      'Rigor::Environment#@missing_rbs_gems' => [%w[Array], input],
      'Rigor::Environment::RbsLoader#@signature_paths' => [%w[Pathname], input],
      'Pathname#@path' => [%w[String], input],
      "Rigor::Inference::HktBody::NominalApp#class_name" =>
        [%w[String], "the bundled HKT definitions' class names, built once at load and never mutated"],
      'Rigor::Environment::RbsLoader#@state' =>
        [%w[Array Hash Set], "the loader's lazy derivations of its inputs (Memos), mixed with warn-once flags and " \
                             "failure counters (output logs); stage 2 splits it before it can be declared"],
      'Rigor::Environment#@hkt_scan_failure' =>
        [%w[Rigor::Environment::FailureSlot], "the first failure the memoised HKT registry build met, read by the " \
                                              "run after analysis, never by typing"],
      'Rigor::Environment#@reporters' => [%w[Rigor::Environment::Reporters], holder],
      'Rigor::Environment::Reporters#@boundary_cross' =>
        [%w[Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter], sink],
      'Rigor::Environment::Reporters#@rbs_extended' => [%w[Rigor::RbsExtended::Reporter], sink],
      'Rigor::Environment::Reporters#@source_rbs_synthesis' => [%w[Rigor::Plugin::SourceRbsSynthesisReporter], sink],
      'Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter#@entries' => [%w[Array], sink],
      'Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter#@mutex' => [%w[Thread::Mutex], sink],
      'Rigor::Plugin::SourceRbsSynthesisReporter#@entries' => [%w[Array], sink],
      'Rigor::Plugin::SourceRbsSynthesisReporter#@seen' => [%w[Hash], sink],
      'Rigor::RbsExtended::Reporter#@deprecated_forms' => [%w[Array], sink],
      'Rigor::RbsExtended::Reporter#@hkt_directive_errors' => [%w[Array], sink],
      'Rigor::RbsExtended::Reporter#@lossy_projections' => [%w[Array], sink],
      'Rigor::RbsExtended::Reporter#@mutex' => [%w[Thread::Mutex], sink],
      'Rigor::RbsExtended::Reporter#@unresolved_payloads' => [%w[Array], sink]
    }
  end

  # The per-file discovery index ScopeIndexer builds before typing starts. Typing reads it and does not write it, but
  # its tables are not frozen deeply.
  def discovery_rows
    built = "built by ScopeIndexer's pre-pass before typing and read, not written, by typing; not frozen deeply"
    index = "Rigor::Scope::DiscoveryIndex"
    {
      "#{index}#contested_discovered_def_nodes" => [%w[Set String], built],
      "#{index}#contested_discovered_method_visibilities" => [%w[Set String], built],
      "#{index}#contested_discovered_parameter_envelopes" => [%w[Array Set String], built],
      "#{index}#contested_discovered_singleton_def_nodes" => [%w[Set String], built],
      "#{index}#data_member_layouts" => [%w[Hash], built],
      "#{index}#discovered_classes" => [%w[Hash], built],
      "#{index}#discovered_def_nestings" => [%w[String], built],
      "#{index}#discovered_def_sources" => [%w[String], built],
      "#{index}#discovered_deferred_ranges" => [%w[Array String], built],
      "#{index}#discovered_extends" => [%w[Array Hash String], built],
      "#{index}#discovered_global_write_census" => [%w[String], built],
      "#{index}#discovered_includes" => [%w[Array Hash String], built],
      "#{index}#discovered_method_visibilities" => [%w[Hash], built],
      "#{index}#discovered_methods" => [%w[Hash], built],
      "#{index}#discovered_parameter_envelopes" => [%w[Array Hash], built],
      "#{index}#discovered_prepends" => [%w[Hash], built],
      "#{index}#discovered_refinements" => [%w[String], built],
      "#{index}#discovered_singleton_def_sources" => [%w[String], built],
      "#{index}#discovered_superclasses" => [%w[Hash String], built],
      "#{index}#possible_discovered_methods" => [%w[Hash], built],
      "#{index}#struct_member_layouts" => [%w[Hash], built],
      "#{index}#unpositioned_mixins" => [%w[String], built],
      'Rigor::Inference::ScopeIndexer::LayeredDefNestings#@file' => [%w[String], built],
      'Rigor::Inference::ScopeIndexer::LayeredDefNestings#@seed' => [%w[String], built]
    }
  end

  def scope_rows
    first_ask = "a first-ask cache keyed on the frame alone, whose computation is handed the asking scope (constant " \
                "resolution, and MatchRebinding.may_match?, which #memo keys on the scope's locals and ivars); " \
                "extensional only if the answer is the same for every scope the frame runs, which is unproven"
    {
      'Rigor::Inference::MatchRebinding::Frame#@matching_closure' => [%w[reassigned], first_ask],
      'Rigor::Inference::MatchRebinding::Frame#@last_line_closure' => [%w[reassigned], first_ask],
      'Rigor::Inference::MatchRebinding::Frame#@last_line_fallback' => [%w[reassigned], first_ask],
      'Rigor::Scope#@source_path' => [%w[String], "the analysed file's path, an unfrozen String the runner passes"],
      'Rigor::Scope#@declaration_sourced' =>
        [%w[Array], "a scope field holding unfrozen Arrays; a Scope is frozen but its fields are not deeply"],
      'Rigor::Scope#@lexical_nesting' =>
        [%w[String], "a scope field holding unfrozen Strings; a Scope is frozen but its fields are not deeply"],
      'Rigor::Scope#@struct_fold_safe_locals' =>
        [%w[Set], "a scope field holding an unfrozen Set; a Scope is frozen but its fields are not deeply"],
      'Rigor::Type::Constant#@value' =>
        [%w[Pathname Regexp], "a Constant type's value is the folded Ruby object itself, which the type does not " \
                              "freeze"],
      "Rigor::Analysis::FactStore::Fact#payload" =>
        [%w[Hash], "a fact's payload Hash is not frozen by construction"]
    }
  end

  def slot_rows
    {
      "slot :user_method_return_memo" =>
        [%w[Array Hash String], "the ADR-84 return memo's slot holds [generation, bucket], whose nested per-def " \
                                "Hashes, Array keys of unfrozen describe Strings and generation tables are not " \
                                "frozen; stage 2's Table conversion owns it"],
      "Rigor::Inference::ExpressionTyper::MemoEntry#arg_types" =>
        [%w[Array], "a return-memo entry keeps the caller's argument-type Array, unfrozen"]
    }
  end

  it "reaches no mutable state outside a slot, a store or a declared Memo, beyond the ratchet" do
    walker = sample_fixtures
    expect(walker.samples).to be > 500
    found = walker.findings.to_h { |field, finding| [field, finding.classes.to_a.sort] }
    allowed = allow_list.transform_values { |classes, _| classes.sort }
    unlisted = found.reject { |field, classes| allowed[field] == classes }
                    .map { |field, classes| "#{field} #{classes.inspect} via #{walker.findings[field].path}" }
    stale = allowed.reject { |field, classes| found[field] == classes }.map { |field, classes| "#{field} #{classes}" }
    expect(unlisted).to be_empty, <<~MESSAGE
      ADR-129 G4: reached a mutable object no declaration accounts for. Freeze it, put it behind a TypingState slot,
      declare the extensional cache with TypingState.memo_field, or add a row with its reason:
        #{unlisted.join("\n  ")}
    MESSAGE
    expect(stale).to be_empty, "ADR-129 G4: rows no longer found as listed; shrink them:\n  #{stale.join("\n  ")}"
  end

  it "gives every ratchet row its classes and a reason" do
    bad = allow_list.reject { |_, (classes, reason)| classes.is_a?(Array) && !classes.empty? && !reason.strip.empty? }
    expect(bad.keys).to be_empty
  end

  # A declaration whose field was renamed away would accept nothing and say nothing.
  it "finds every declared field assigned in its owner's source" do
    sources = Dir.glob("lib/**/*.rb").map { |path| File.read(path) }
    missing = Rigor::TypingState.fields.reject do |field|
      opener = /^\s*class #{Regexp.escape(field.owner.name.split('::').last)}\b/
      assignment = /#{Regexp.escape(field.ivar.to_s)}\s*(\|\|)?=[^=]/
      sources.any? { |text| text.match?(opener) && text.match?(assignment) }
    end
    expect(missing.map { |field| "#{field.owner}##{field.ivar}" }).to be_empty
  end

  describe "the walker" do
    let(:holder_class) do
      Class.new do
        attr_writer :cache, :input

        def initialize
          @cache = nil
          @input = "fixed"
        end

        def self.name = "Holder"
      end
    end

    def field(owner, ivar, kind = :memo) = Rigor::TypingState::Field.new(owner:, ivar:, kind:, slot: nil, reason: "r")

    def walk(root, fields: [], slots: [], state: [], times: 1)
      walker = TypingStateReachability::Walker.new(fields: fields, slots: slots)
      times.times { walker.sample(root, state) }
      walker.findings.to_h { |name, finding| [name, finding.classes.to_a.sort] }
    end

    it "accepts frozen objects and walks into them" do
      expect(walk({ a: [1, "s"].freeze }.freeze)).to eq({})
      expect(walk({ a: [1, +"s"].freeze }.freeze)).to eq("scope" => %w[String])
    end

    it "keys a finding on the instance variable of the object that holds it" do
      holder = holder_class.new.freeze
      object = holder_class.new
      object.input = +"mutable"
      expect(walk({ h: object }.freeze)).to eq("scope" => %w[Holder], 'Holder#@input' => %w[String])
      expect(walk(holder)).to eq({})
    end

    it "accepts a declared memo field without walking it, and its holder while the other fields stay put" do
      object = holder_class.new
      object.cache = { k: +"v" }
      expect(walk(object, fields: [field(holder_class, :@cache)])).to eq({})
    end

    it "reports an undeclared field of a memo holder that takes a new object between samples" do
      object = holder_class.new
      walker = TypingStateReachability::Walker.new(fields: [field(holder_class, :@cache)], slots: [])
      walker.sample(object, [])
      object.input = "other"
      walker.sample(object, [])
      expect(walker.findings.keys).to eq(['Holder#@input'])
      expect(walker.findings['Holder#@input'].classes.to_a).to eq(["reassigned"])
    end

    it "accepts a store field's container and walks its entries" do
      store = { node: :cause }
      expect(walk(holder_class.new.tap { |o| o.cache = store }.freeze, fields: [field(holder_class, :@cache, :store)]))
        .to eq({})
      store[:node] = +"mutable"
      expect(walk(holder_class.new.tap { |o| o.cache = store }.freeze, fields: [field(holder_class, :@cache, :store)]))
        .to eq('Holder#@cache' => %w[String])
    end

    it "walks a Frame slot's value except its declared memos, and accepts a Resource slot's whole" do
      frame = Rigor::TypingState.slot(:file_digest_run).with(index: 0)
      value = { digests: { "p" => +"d" }, stats: [], instant: +"t" }.freeze
      expect(walk(nil, slots: [frame], state: [value])).to eq("slot :file_digest_run" => %w[String])
      resource = frame.with(kind: :resource, memos: nil)
      expect(walk(nil, slots: [resource], state: [{ a: +"x" }])).to eq({})
      bare = frame.with(memos: nil)
      expect(walk(nil, slots: [bare], state: [value])).to eq("slot :file_digest_run" => %w[Array Hash String])
    end

    it "does not report an object it accepts on another path in the same sample" do
      shared = { k: +"v" }
      object = holder_class.new
      object.cache = shared
      object.input = shared
      root = [object].freeze
      expect(walk(root, fields: [field(holder_class, :@cache)])).to eq({})
    end
  end
end
