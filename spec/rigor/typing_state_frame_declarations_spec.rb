# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# ADR-129 WD5 / G1' — each Frame slot declares one of four things about how typing meets it: a witness fixture,
# `typing_unreachable`, `typing_never_reads` or `memo_shut_while_installed`. This spec holds the registry to that, runs
# each witness fixture to show typing installs its Frame and reads it inside `type_of` (G1, which will fail each
# witness with its slot ignored, does not exist yet), and drives the two declarations audit mode asserts.

module TypingStateFrameDeclarationsSpec
  # Observes the Frame reads inside `type_of`: `READ` holds every Frame read there, `SEEN` those that answered a value
  # (a Frame installed during a typing and read there).
  # Extended onto the thread's state before a run, below {Rigor::TypingState::FrameAudit}, which the first audited
  # `type_of` extends later and which knows the depth.
  module ReadObserver
    SEEN = Set.new
    READ = Set.new

    class << self
      attr_accessor :recording

      def note(state, slot, value)
        return unless recording && state.respond_to?(:type_of_depth) && state.type_of_depth.to_i.positive?

        name = Rigor::TypingState.slots[slot].name
        READ << name
        SEEN << name unless value.nil?
      end
    end

    def [](slot)
      value = super
      ReadObserver.note(self, slot, value)
      value
    end

    def key_frame(slot)
      value = super
      ReadObserver.note(self, slot, value)
      value
    end
  end
end

RSpec.describe "ADR-129 G1' Frame declarations", type: :runner do
  let(:state_module) { Rigor::TypingState }
  let(:audit) { Rigor::MemoAudit }
  let(:repo_root) { File.expand_path("../..", __dir__) }

  def frames = state_module.slots.select { |slot| slot.kind == :frame }

  def declared(kind) = frames.select { |slot| slot.declaration.first == kind }

  describe "the registry" do
    it "gives every Frame exactly one declaration, and no other slot one" do
      kinds = frames.map { |slot| slot.declaration&.first }
      expect(kinds).to all(satisfy { |kind| state_module::G1_KINDS.include?(kind) })
      expect(state_module.slots.reject { |slot| slot.kind == :frame }.map(&:declaration)).to all(be_nil)
    end

    it "finds every witness fixture on disk, repo-relative, and under the witness directory" do
      paths = declared(:witness).map { |slot| slot.declaration.last }.uniq

      expect(paths).to all(start_with("spec/fixtures/typing_state_witnesses/"))
      expect(paths.reject { |path| File.file?(File.join(repo_root, path)) }).to be_empty
    end

    it "leaves no fixture in the witness directory that no Frame names" do
      named = declared(:witness).to_set { |slot| slot.declaration.last }
      on_disk = Dir.glob(File.join(repo_root, "spec/fixtures/typing_state_witnesses/*.rb"))
                   .map { |path| path.delete_prefix("#{repo_root}/") }

      expect(on_disk.reject { |path| named.include?(path) }).to be_empty
    end

    it "refuses a Frame that declares none, or more than one" do
      kinds = state_module::G1_KINDS.to_h { |kind| [kind, kind == :witness ? "a.rb" : true] }
      expect { state_module.frame(:g1_probe, reason: "x") }.to raise_error(ArgumentError, /exactly one/)
      kinds.keys.combination(2).each do |first, second|
        expect { state_module.frame(:g1_probe, reason: "x", first => kinds[first], second => kinds[second]) }
          .to raise_error(ArgumentError, /exactly one/)
      end
      expect { state_module.frame(:g1_probe, reason: "x", typing_never_reads: false) }
        .to raise_error(ArgumentError, /exactly one/)
      expect do
        state_module.frame(:g1_probe, reason: "x", witness: "/abs/a.rb")
      end.to raise_error(ArgumentError, /witness/)
      expect(state_module.slots.map(&:name)).not_to include(:g1_probe)
    end

    it "records each kind as a frozen [kind, argument] pair" do
      expect(state_module.slot(:threaded_block_body).declaration)
        .to eq([:witness, "spec/fixtures/typing_state_witnesses/threaded_block_body.rb"])
      expect(state_module.slot(:flow_tracer).declaration).to eq([:memo_shut_while_installed, true])
      expect(state_module.slot(:patched_scanner_guarded_defs).declaration).to eq([:typing_unreachable, true])
      expect(state_module.slot(:declared_param_writer_scope).declaration).to eq([:typing_never_reads, true])
      expect(frames.map(&:declaration)).to all(be_frozen)
    end
  end

  describe "the witness fixtures" do
    around do |example|
      audit.enable!
      audit.drain
      Rigor::TypingState.current.extend(TypingStateFrameDeclarationsSpec::ReadObserver)
      TypingStateFrameDeclarationsSpec::ReadObserver::SEEN.clear
      TypingStateFrameDeclarationsSpec::ReadObserver::READ.clear
      TypingStateFrameDeclarationsSpec::ReadObserver.recording = true
      example.run
    ensure
      TypingStateFrameDeclarationsSpec::ReadObserver.recording = false
      audit.drain
      audit.disable!
      Rigor::TypingState.release_run_scoped
    end

    def run_source(source, signature_dir: nil, cache_store: nil, **options)
      configuration = Rigor::Configuration.new(
        { "bundler" => { "auto_detect" => false }, "rbs_collection" => { "auto_detect" => false },
          "signature_paths" => [signature_dir].compact }.merge(options.delete(:config) || {})
      )
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: cache_store, workers: 0,
                                           **options)
      guarded_run_source(runner, source: source, path: "code.rb")
    rescue InternalAnalyzerErrorGuard::AnalyzerCrashed => e
      # The key audit's own findings on a witness run are not this spec's subject (key_presence_walk's rewalk miss
      # reads a Frame its key does not carry); any other crash is.
      raise unless e.message.include?("key audit:")
    end

    # An `IncrementalSession` over the fixture's project (the sibling directory of the witness) with the witness as its
    # consumer: after the baseline a file is edited and the recheck types the consumer against handles of the unchanged
    # files. The key audit's own findings (#2874) are not this spec's subject.
    def run_incremental_witness(path)
      Dir.mktmpdir do |dir|
        FileUtils.cp(Dir.glob(path.sub(/\.rb\z/, "/*.rb")), dir)
        FileUtils.cp(path, File.join(dir, "b.rb"))
        configuration = Rigor::Configuration.new("paths" => [dir])
        environment = Rigor::Environment.for_project
        session = Rigor::Analysis::IncrementalSession.new(configuration: configuration, paths: [dir],
                                                          environment: environment)
        tolerating_key_audit { guarded_baseline(session) }
        File.write(File.join(dir, "q.rb"), "module R\nend\n\nmodule Q\n  def tweak = 1\nend\n")
        tolerating_key_audit { guarded_recheck(session) }
      end
    end

    def tolerating_key_audit
      yield
    rescue InternalAnalyzerErrorGuard::AnalyzerCrashed => e
      raise unless e.message.include?("key audit:")
    end

    # How a witness's slot is installed, where a plain run does not: the harnesses the engine's own entry points use.
    # A diagnostic of the run is not asserted: the examples ask only whether typing read the Frame.
    def run_witness(name, path)
      Dir.mktmpdir do |dir|
        sibling = path.sub(/\.rb\z/, ".rbs")
        FileUtils.cp(sibling, File.join(dir, "witness.rbs")) if File.file?(sibling)
        source = File.read(path)
        case name
        when :interface_erasure
          Rigor::Inference::RbsTypeTranslator.with_interface_erasure { run_source(source, signature_dir: dir) }
        when :interface_dispatch_off
          Rigor::Inference::MethodDispatcher::RbsDispatch.without_interface_dispatch do
            run_source(source, signature_dir: dir)
          end
        when :self_call_resolution_recorder then run_source(source, signature_dir: dir, record_self_calls: true)
        when :def_node_resolver_run then run_incremental_witness(path)
        when :dependency_recorder then run_source(source, signature_dir: dir, record_dependencies: true)
        when :effects_collector then run_source(source, signature_dir: dir, config: { "effects" => {} })
        when :file_digest_run then analyze(source)
        when :rbs_core_root
          # A cold cache store and an unmemoised build, so the lazy build runs inside the `type_of`. A configured
          # `core_root` builds the environment eagerly, outside it, so only the default (nil) core root is read there.
          analyze(source, cache_store: Rigor::Cache::Store.new(root: File.join(dir, "cache")))
        else run_source(source, signature_dir: dir)
        end
      end
    end

    # A witness whose Frame typing reads only while it holds nil, and why. The environment builds eagerly, outside any
    # `type_of`, whenever `core_root:` is configured, so the lazy build that runs inside one has no core root to read.
    def nil_only = { rbs_core_root: "a configured core root builds the environment eagerly, outside type_of" }

    declared_slots = Rigor::TypingState.slots.select { |slot| slot.kind == :frame && slot.declaration.first == :witness }
    declared_slots.each do |slot|
      it "types #{slot.name} installed and reads it inside type_of", :fresh_rbs_env do
        run_witness(slot.name, File.join(repo_root, slot.declaration.last))

        observer = TypingStateFrameDeclarationsSpec::ReadObserver
        expect(observer::READ).to include(slot.name)
        expect(observer::SEEN).to include(slot.name) unless nil_only.key?(slot.name)
      end
    end
  end

  describe "the audit assertions" do
    let(:state) { Rigor::TypingState.current }
    let(:probe_node) { Prism.parse("1 + 1").value.statements.body.first }

    around do |example|
      audit.enable!
      audit.drain
      example.run
    ensure
      audit.drain
      audit.disable!
      Rigor::TypingState.release_run_scoped
    end

    def slot_index(name) = state_module.slot(name).index

    def typed_in_scope = Rigor::Scope.empty.type_of(probe_node)

    def mismatches = audit.drain

    context "with typing_unreachable" do
      it "reports a type_of that runs while the Frame is installed" do
        state.with(slot_index(:patched_scanner_guarded_defs), {}.freeze) { typed_in_scope }

        expect(mismatches.map(&:message))
          .to eq(["frame audit: type_of ran while the typing_unreachable Frame patched_scanner_guarded_defs " \
                  "is installed"])
      end

      it "keeps the type_of's answer and reports nothing once the Frame is out, or while it is installed as nil" do
        state.with(slot_index(:patched_scanner_guarded_defs), {}.freeze) { nil }
        state.with(slot_index(:patched_scanner_guarded_defs), nil) { typed_in_scope }
        expect(typed_in_scope).to be_a(Rigor::Type::Constant).or be_a(Rigor::Type::Nominal)

        expect(mismatches).to be_empty
      end

      it "reports one mismatch per message until drained" do
        state.with(slot_index(:patched_scanner_def_visibilities), {}.freeze) { 2.times { typed_in_scope } }

        expect(mismatches.size).to eq(1)
      end
    end

    context "with typing_never_reads" do
      let(:slot) { slot_index(:declared_param_writer_scope) }

      it "reports a read of the Frame inside a type_of" do
        audit.enter_type_of
        begin
          state[slot]
        ensure
          audit.leave_type_of
        end

        expect(mismatches.map(&:message))
          .to eq(["frame audit: the typing_never_reads Frame declared_param_writer_scope was read inside type_of"])
      end

      it "reports a key_frame read and a forcing_read inside a type_of alike" do
        audit.enter_type_of
        begin
          state.key_frame(slot)
          state.forcing_read(slot)
        ensure
          audit.leave_type_of
        end

        expect(mismatches.size).to eq(1)
      end

      it "reports nothing for a read outside a type_of, or of a Frame that declares another kind, inside one" do
        audit.enter_type_of
        audit.leave_type_of
        state[slot]
        audit.enter_type_of
        begin
          state[slot_index(:yield_value_type)]
        ensure
          audit.leave_type_of
        end

        expect(mismatches).to be_empty
      end

      it "reports a read after a type_of ended inside the same thread only while another is running" do
        audit.enter_type_of
        audit.enter_type_of
        audit.leave_type_of
        state[slot]
        audit.leave_type_of

        expect(mismatches.size).to eq(1)
      end
    end
  end
end
