# frozen_string_literal: true

require "spec_helper"

require "rigor/analysis/runner"
require "rigor/configuration"

# ADR-129 G4 — the reachability audit. While Rigor analyses the integration fixtures, every {#stride}th
# `ExpressionTyper#type_of` call of each file is sampled ({TypingStateReachability.sample}): the walker
# ({TypingStateReachability::Walker}) follows everything
# reachable from that call's scope, `scope.environment` included, and from the slot values of the thread's
# TypingState, and reports each mutable object that is not frozen, a Prism node, a slot's storage, a bound Table's
# store or a declared Memo ({Rigor::TypingState.memo_field}, a Memo slot, a Frame's `memos:`).
#
# The findings no declaration accounts for are listed in {#allow_list}, one row per field with the classes found there
# and why the field is not yet a slot or a Memo. A field that is not listed and a class a row does not name fail, at any
# sampling phase: the rows are the union of what every offset of the stride finds. In the default run (stride 50,
# offset 0) the rows are strict, so the list only shrinks: a row whose field has no finding, and a listed class not
# found, fail as stale. The few fields that hold something mutable at only some calls are named in {#sparse_rows}, each
# with why; such a row is stale only when the walk never passes through its field, and its classes need only cover
# what is found. Growing either list needs a reason a reviewer accepts. `RIGOR_G4_STRIDE` and `RIGOR_G4_OFFSET` move
# the sample, to check that the rows hold at another phase; a moved sample holds every row to the sparse rule.
RSpec.describe "ADR-129 G4: what a type_of call can reach" do
  # Every top-level `.rb` fixture, analysed in one sequential run with no cache. The stride keeps the walk to about
  # 1,200 samples.
  def stride = Integer(ENV.fetch("RIGOR_G4_STRIDE", "50"))
  def offset = Integer(ENV.fetch("RIGOR_G4_OFFSET", "0"))

  def fixture_paths = Dir.glob("spec/integration/fixtures/*.rb")

  def sample_fixtures
    paths = fixture_paths
    TypingStateReachability.sample(paths, stride: stride, offset: offset) { |runner| guarded_run(runner, paths) }
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
                "extensional only if the answer is the same for every scope the frame runs, which is unproven (#2864)"
    {
      'Rigor::Inference::MatchRebinding::Frame#@matching_closure' => [%w[reassigned], first_ask],
      'Rigor::Inference::MatchRebinding::Frame#@last_line_closure' => [%w[reassigned], first_ask],
      'Rigor::Inference::MatchRebinding::Frame#@last_line_fallback' => [%w[reassigned], first_ask],
      'Rigor::Scope#@source_path' => [%w[String], "the analysed file's path, an unfrozen String the runner passes"],
      'Rigor::Scope#@declaration_sourced' =>
        [%w[Array], "a scope field holding unfrozen Arrays; a Scope is frozen but its fields are not deeply"],
      'Rigor::Scope#@lexical_nesting' =>
        [%w[String], "a scope field holding unfrozen Strings; a Scope is frozen but its fields are not deeply"],
      'Rigor::Scope#@bot_guard_classes' =>
        [%w[String], "a bot guard's class names, kept in a frozen Array whose Strings are not frozen; a Scope is " \
                     "frozen but its fields are not deeply"],
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
      "slot :scope_index_unentered_evaluator" =>
        [%w[Proc], "the frozen lambda ScopeIndexer installs around its index walk; it closes over the walk's own " \
                   "table, which it writes (the walk's state, not typing state, per the slot's reason), and the " \
                   "walk's converged-loop recording and clause widening, which it reads"],
      "slot :user_method_return_memo" =>
        [%w[Array Hash String], "the ADR-84 return memo's slot holds [generation, bucket], whose nested per-def " \
                                "Hashes, Array keys of unfrozen describe Strings and generation tables are not " \
                                "frozen; stage 2's Table conversion owns it"],
      "Rigor::Inference::ExpressionTyper::MemoEntry#arg_types" =>
        [%w[Array], "a return-memo entry keeps the caller's argument-type Array, unfrozen"]
    }
  end

  # The rows whose field holds something mutable at only some of the sampled calls: the fields the 58-run union over
  # every offset of stride 50 (and strides 25, 37, 150 and 1000) found at fewer than all phases. Every sample visits
  # these fields, so the stale check can never fire for them: a row here that a later change freezes for good stays
  # until someone removes it by hand.
  def sparse_rows
    lazy = "set lazily by the first ask in a frame; a frame whose first ask falls before a sample and after the " \
           "frame was first reached is not met at every phase"
    transient = "holds an unfrozen object only while a narrowing or a declaration of that kind is in effect at the " \
                "sampled call; otherwise the shared frozen empty default"
    {
      'Rigor::Inference::MatchRebinding::Frame#@last_line_closure' => lazy,
      'Rigor::Inference::MatchRebinding::Frame#@last_line_fallback' => lazy,
      'Rigor::Scope#@bot_guard_classes' => transient,
      'Rigor::Scope#@declaration_sourced' => transient,
      'Rigor::Scope#@lexical_nesting' => transient,
      'Rigor::Scope#@struct_fold_safe_locals' => transient
    }
  end

  def default_phase? = stride == 50 && offset.zero?

  it "names only listed rows as sparse, each with a reason" do
    expect(sparse_rows.keys - allow_list.keys).to be_empty
    expect(sparse_rows.values.map(&:strip)).to all(satisfy { |reason| !reason.empty? })
  end

  it "reaches no mutable state outside a slot, a store or a declared Memo, beyond the ratchet" do
    walker = sample_fixtures
    expect(walker.samples).to be > 20_000 / stride
    found = walker.findings.to_h { |field, finding| [field, finding.classes.to_a.sort] }
    allowed = allow_list.transform_values(&:first)
    unlisted = found.reject { |field, classes| allowed.key?(field) && (classes - allowed[field]).empty? }
                    .map { |field, classes| "#{field} #{classes.inspect} via #{walker.findings[field].path}" }
    stale = allowed.filter_map do |field, classes|
      if !default_phase? || sparse_rows.key?(field)
        "#{field} (never reached)" unless walker.observed.include?(field)
      elsif found[field] != classes.sort
        "#{field} #{classes.sort.inspect}, found #{found.fetch(field, []).inspect}"
      end
    end
    expect(unlisted).to be_empty, <<~MESSAGE
      ADR-129 G4: reached a mutable object no declaration accounts for. Freeze it, put it behind a TypingState slot,
      declare the extensional cache with TypingState.memo_field, or add a row with its reason:
        #{unlisted.join("\n  ")}
    MESSAGE
    expect(stale).to be_empty,
                     "ADR-129 G4: rows no longer found as listed; shrink them:\n  #{stale.join("\n  ")}"
  end

  it "gives every ratchet row its classes and a reason" do
    bad = allow_list.reject { |_, (classes, reason)| classes.is_a?(Array) && !classes.empty? && !reason.strip.empty? }
    expect(bad.keys).to be_empty
  end

  # Every class body in lib, by its qualified name (a class reopened in several files has several).
  def class_bodies
    bodies = Hash.new { |hash, name| hash[name] = [] }
    collect = lambda do |node, nesting|
      if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        nesting = [*nesting, node.constant_path.slice]
        bodies[nesting.join("::")] << node.body if node.body
      end
      node.compact_child_nodes.each { |child| collect.call(child, nesting) }
    end
    Dir.glob("lib/**/*.rb").each { |path| collect.call(Prism.parse_file(path).value, []) }
    bodies
  end

  # A declaration whose field was renamed away would accept nothing and say nothing.
  it "finds every declared field assigned in its owner's own class body" do
    bodies = class_bodies
    missing = Rigor::TypingState.fields.reject do |field|
      assignment = /#{Regexp.escape(field.ivar.to_s)}\s*(\|\|)?=[^=]/
      bodies[field.owner.name].any? { |body| body.slice.match?(assignment) }
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

    it "carries a cycle's taint to a later visit, so a cycle member is not cached as deeply frozen" do
      inner = { k: 1 }
      cycle = []
      back = [cycle].freeze
      cycle << back << inner
      cycle.freeze
      outer = [back].freeze
      walker = TypingStateReachability::Walker.new(fields: [], slots: [])
      walker.sample([cycle, outer].freeze, [])
      inner[:x] = +"new"
      walker.sample(outer, [])
      expect(walker.findings["scope"].classes.to_a.sort).to eq(%w[Hash String])
    end

    it "reports a Proc, frozen or not, and walks a Hash's default_proc" do
      expect(walk({ p: -> {}.freeze }.freeze)).to eq("scope" => %w[Proc])
      expect(walk(Hash.new { |_, key| key }.freeze)).to eq("scope" => %w[Proc])
    end

    it "checks a memo holder once more when the run ends, whatever the sampling phase" do
      object = holder_class.new
      walker = TypingStateReachability::Walker.new(fields: [field(holder_class, :@cache)], slots: [])
      walker.sample(object, [])
      object.input = "other"
      expect(walker.finish.findings.keys).to eq(['Holder#@input'])
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
