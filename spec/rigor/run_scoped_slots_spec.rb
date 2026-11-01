# frozen_string_literal: true

# Issue #2412 — `LoopValueRecord` and the inject-accumulator record kept every finished run alive: each is an
# `ObjectSpace::WeakKeyMap` keyed by a node, whose strong value (a scope) reaches the parse tree that holds the key,
# so neither entry was ever collected and every run on the same thread (`check` or `sig-gen` repeated in one process)
# added its whole analysis to the heap. Both are run-scoped slots ({Rigor::RunScopedSlots}), emptied when a run ends.
#
# Issue #2399 — about twenty other per-thread memo slots held the last run's discovery tables and environment until
# the next run on the thread replaced them. They are registered too, so a finished run leaves none of them behind.

require "spec_helper"
require "fileutils"
require "tmpdir"
require "prism"
require "rigor/language_server"

RSpec.describe Rigor::RunScopedSlots do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) do
    full = File.join(tmpdir, "lib/looper.rb")
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, <<~RUBY)
      class Looper
        def first(items)
          found = while items.any?
                    break items.first
                  end
          found.to_s
        end

        def total = [1, 2].inject(0) { |sum, item| sum + item }

        def wrapped = id(first([1]))

        def id(value) = value

        def fill(acc)
          stripes(acc)
          acc
        end

        def stripes(acc) = acc << 1
      end
    RUBY
    full
  end
  let(:configuration) { Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [path])) }

  # The per-thread keys `lib/` names that are deliberately not run-scoped, each with why. A frame slot is one a
  # `with_*`-style block installs and restores on the way out, so it is already empty when the run's frame returns,
  # and clearing it from inside a frame would break that frame.
  let(:not_run_scoped) do
    {
      __rigor_acceptance_unread_shape_refused__: "frame flag, installed and restored around a block",
      __rigor_declared_param_writer_scope__: "frame slot, installed and restored around a block",
      __rigor_dependency_capture_stack__: "frame slot of the ADR-46 dependency recorder",
      __rigor_dependency_recorder__: "frame slot of the ADR-46 dependency recorder",
      __rigor_effects_collector__: "frame slot of the effects collector",
      __rigor_flow_tracer__: "frame slot of the flow tracer",
      __rigor_forwarded_call_arg_types__: "frame slot, installed and restored around a block",
      __rigor_key_presence_guard: "frame slot of KeyPresenceGuard.with_guards",
      __rigor_project_round__: "a Debouncer key in the language server, not a thread-local",
      __rigor_reflective_ivar_write_repeating__: "frame depth counter, restored on the way out",
      __rigor_self_call_resolution_recorder__: "frame slot of the self-call resolution recorder",
      __rigor_threaded_block_body__: "frame flag, installed and restored around a block",
      __rigor_user_method_inference_stack__: "ADR-55 guard stack, popped to empty by each frame",
      __rigor_user_method_return_summary__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_user_method_summary_consult_depths__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_user_method_transient_event_depths__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_user_method_unroll_fuel__: "ADR-55 state, cleared when the guard stack drains",
      __rigor_yield_value_type__: "frame slot, installed and restored around a block",
      rigor_memo_audit_suspended: "frame flag of MemoAudit, installed and restored around a recomputation",
      rigor_break_sink: "jump sink frame, installed and restored around a loop",
      rigor_break_value_sink: "jump sink frame, installed and restored around a loop",
      rigor_cache_file_digest_memo: "Cache::FileDigest.with_run frame",
      rigor_cache_file_stat_memo: "Cache::FileDigest.with_run frame",
      rigor_cache_recording_instant: "Cache::FileDigest.with_run frame",
      rigor_cache_strict_validation: "Cache::FileDigest.with_run frame",
      rigor_def_node_resolver_memo: "DefNodeResolver.with_run frame",
      rigor_def_visibilities: "per-file scan state, cleared in the scanner's ensure",
      rigor_guarded_defs: "per-file scan state, cleared in the scanner's ensure",
      rigor_io_boundary_attribution: "thread-variable frame, installed and restored around a block",
      rigor_next_sink: "jump sink frame, installed and restored around a block",
      rigor_provisional_returns: "return sink frame, installed and restored around a body",
      rigor_rbs_core_root: "RbsLoader.with_core_root frame, installed and restored around an env build",
      rigor_retry_frames: "frame stack of the enclosing `begin` / `retry` edges",
      rigor_return_sink: "return sink frame, installed and restored around a body",
      rigor_run_disclosure_attribution: "thread-variable frame, installed and restored around a block",
      rigor_scope_index_unentered_evaluator: "frame slot, installed and restored around the index walk"
    }
  end

  after do
    FileUtils.remove_entry(tmpdir)
    loop_keys.each { |key| Thread.current[key] = nil }
  end

  def check_run = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), [path])

  def sig_gen_run = Rigor::SigGen::Generator.new(configuration: configuration, paths: [path]).run

  def loop_keys = %i[rigor_loop_value_record __rigor_inject_accumulator__]

  # The keys of `loop_keys` that hold something when the run calls {.release}, so an example reads a slot the run
  # really filled.
  def filled_at_release(keys)
    filled = []
    allow(described_class).to receive(:release).and_wrap_original do |original|
      filled.concat(keys.reject { |key| Thread.current[key].nil? })
      original.call
    end
    filled
  end

  def settled_environments
    4.times { GC.start(full_mark: true, immediate_sweep: true) }
    ObjectSpace.each_object(Rigor::Environment).count
  end

  { "Runner#run" => :check_run, "SigGen::Generator#run" => :sig_gen_run }.each do |entry_point, run|
    context "with #{entry_point}" do
      it "empties the loop-value and inject-accumulator records the run filled" do
        filled = filled_at_release(loop_keys)

        send(run)

        expect(filled).to match_array(loop_keys)
        expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
      end

      it "leaves no environment of its own behind" do
        # An earlier example's run may still be held by a slot nothing has released yet; start from none.
        Thread.current.keys.grep(/rigor/).each { |key| Thread.current[key] = nil }
        before = settled_environments
        send(run)

        expect(settled_environments).to eq(before)
      end

      # A slot a new owner adds is caught here until it is registered: the run fills it and nothing empties it.
      it "leaves every per-thread memo slot empty" do
        send(run)

        holding = Thread.current.keys.grep(/rigor/).reject do |key|
          value = Thread.current[key]
          value.nil? || value == 0 || (value.respond_to?(:empty?) && value.empty?)
        end
        expect(holding).to be_empty
        expect(described_class.keys.map { |key| Thread.current[key] }).to all(be_nil)
      end

      it "retains no more environments after the third run than after the first" do
        send(run)
        after_first = settled_environments
        2.times { send(run) }

        expect(settled_environments).to eq(after_first)
      end
    end
  end

  # A language-server provider types on the main thread outside any run, filling the same slots; one a run released
  # under it refills on its first miss and answers as before.
  it "answers a hover the same after the slots it filled are released" do
    buffer_table = Rigor::LanguageServer::BufferTable.new
    context = Rigor::LanguageServer::ProjectContext.new(configuration: Rigor::Configuration.new("paths" => []))
    provider = Rigor::LanguageServer::HoverProvider.new(buffer_table: buffer_table, project_context: context)
    uri = "file://#{tmpdir}/hover.rb"
    buffer_table.open(uri: uri, bytes: <<~RUBY, version: 1)
      class Greeter
        def name = [1, 2].map(&:to_s).first
        def greet = name
      end
      Greeter.new.greet
    RUBY
    hover = -> { provider.provide(uri: uri, line: 4, character: 12)&.dig(:contents, :value) }

    described_class.release
    first = hover.call
    filled = described_class.keys.reject { |key| Thread.current[key].nil? }
    described_class.release

    expect(filled).not_to be_empty
    expect(first).to include(%(type:   "1"))
    expect(hover.call).to eq(first)
  end

  it "empties the slots when the incremental session's return-type probe ends" do
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    allow(runner).to receive(:evaluate_return_types_setup) do
      loop_keys.each { |key| Thread.current[key] = :filled }
      {}
    end

    runner.evaluate_return_types([path], [{ class_name: "Looper", method_name: :id, singleton: false }])

    expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
  end

  it "empties the records when a run raises" do
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    allow(runner).to receive(:run_analysis) do
      loop_keys.each { |key| Thread.current[key] = :filled }
      raise "boom"
    end

    expect { guarded_run(runner, [path]) }.to raise_error(RuntimeError, "boom")
    expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
  end

  it "empties the records when a sig-gen run raises" do
    generator = Rigor::SigGen::Generator.new(configuration: configuration, paths: [path])
    allow(generator).to receive(:analyse_file) do
      loop_keys.each { |key| Thread.current[key] = :filled }
      raise "boom"
    end

    expect { generator.run }.to raise_error(RuntimeError, "boom")
    expect(loop_keys.map { |key| Thread.current[key] }).to all(be_nil)
  end

  # Every per-thread key `lib/` names, and the accesses it cannot resolve. A key is a symbol read through
  # `Thread.current[...]` or `thread_variable_get` / `_set`, directly or through a constant whatever its symbol is
  # spelled (#2458: a trailing comment on the constant or no `rigor` in the name), and every `*_KEY` / `*MEMO*`
  # constant whose `rigor` symbol is a key passed on through a variable, as the RBS ancestor-dispatch memos are.
  def thread_keys_in_lib
    lib = File.expand_path("../../lib", __dir__)
    keys = {}
    unresolved = []
    Dir[File.join(lib, "**/*.rb")].each { |path| scan_thread_keys(File.read(path), path, keys, unresolved) }
    [keys, unresolved]
  end

  # Adds one file's keys (symbol => path) and its unresolved accesses ("path:line NAME") to `keys` and `unresolved`.
  # A dynamic key (a local variable read from a list of constants) is not scanned here; its constants are.
  # The source with every real comment blanked to spaces, so an access a comment spells out is not read, while a `#`
  # inside a string or a regexp hides nothing. Prism gives comment ranges as byte offsets, so the blanking works on a
  # binary copy; the spaces keep every offset and line number.
  def blank_comments(source)
    bytes = source.b
    Prism.parse(source).comments.each do |comment|
      location = comment.location
      bytes[location.start_offset, location.length] = " " * location.length
    end
    bytes.force_encoding(source.encoding)
  end

  def scan_thread_keys(source, path, keys, unresolved)
    source = blank_comments(source)
    scan_thread_accesses(source, path, keys, unresolved, scan_thread_constants(source, path, keys))
  end

  # The constants a file defines as symbols, by name; a `*_KEY` / `*MEMO*` one with a `rigor` symbol is a key.
  def scan_thread_constants(source, path, keys)
    constants = {}
    source.scan(/^\s*([A-Z][A-Z0-9_]*) = (?:RunScopedSlots\.register\()?(:[A-Za-z0-9_]+)\)?\s*(?:#.*)?$/) do
      name, symbol = Regexp.last_match.captures
      constants[name] = symbol
      next unless name.end_with?("_KEY") || name.include?("MEMO")

      keys[symbol.delete_prefix(":").to_sym] = path if symbol.include?("rigor")
    end
    constants
  end

  # The one assignment `lib/` may make of `Thread.current`: the `thread = Thread.current` that `release` empties the
  # slots through. It is allowed only as the file's sole such assignment, and only inside `def release`.
  def alias_allowlist = { "lib/rigor/run_scoped_slots.rb" => { line: "thread = Thread.current", in_def: "release" } }

  # #2572: the access shapes are `Thread.current[`, `thread_variable_get` / `_set` with or without parentheses, and
  # `fetch` / `key?` / `store` on the thread. A key is a symbol or a constant of this file; a dynamic key (a local
  # variable) is skipped, and the constants it is read from are scanned. Anything else is unresolved: a quoted or
  # top-level key, a namespaced constant (never resolved to this file's own), and an access the scan cannot name.
  def scan_thread_accesses(source, path, keys, unresolved, constants)
    code = source
    direct, dynamic = scan_thread_key_reads(code, path, keys, unresolved, constants)
    scan_fiber_reads(code, path, unresolved)
    scan_alias_assignments(code, path, unresolved)
    scan_unread_key_constants(code, path, unresolved, constants, direct) if dynamic
  end

  def thread_key_read
    /Thread\.current(?:\[|\.(?:thread_variable_[gs]et|thread_variable\?|fetch|key\?|store)(?!\w)\(?)[ \t]*([^\]),\n]*)/
  end

  # Returns the constants the file reads directly, and whether it reads a key through a local variable.
  def scan_thread_key_reads(source, path, keys, unresolved, constants)
    direct = []
    dynamic = false
    source.scan(thread_key_read) do
      match = Regexp.last_match
      arg = match[1].strip
      if (symbol = arg[/\A:([a-z_]\w*)\z/i, 1])
        keys[symbol.to_sym] = path
      elsif arg.match?(/\A[a-z_]\w*\z/)
        dynamic = true
      elsif (name = resolved_constant(arg, constants))
        direct << name
        keys[constants[name].delete_prefix(":").to_sym] = path
      else
        unresolved << "#{path}:#{line_at(source, match.begin(0))} #{unresolved_label(arg)}"
      end
    end
    [direct, dynamic]
  end

  # The file's own constant an access names, or nil. A namespaced reference (`Other::KEY`, `::KEY`) names nothing here.
  def resolved_constant(arg, constants)
    constant = arg.match(/\A([A-Z]\w*)\z/)
    constant && constants.key?(constant[1]) ? constant[1] : nil
  end

  # The report label of an unresolved argument: a constant's whole name without its namespace, otherwise as written.
  def unresolved_label(arg)
    constant = arg.match(/\A(?:::)?(?:[A-Z]\w*::)*([A-Z]\w*)\z/)
    constant ? constant[1] : arg
  end

  # A `Fiber[...]` access always fails, whatever its key, until it gets its own allowlist entry. That is the intended
  # fail-closed rule: fiber storage is not a thread key this registry releases.
  def scan_fiber_reads(source, path, unresolved)
    source.scan(/Fiber(?:\.current)?\[([^\]\n]*)/) do
      match = Regexp.last_match
      unresolved << "#{path}:#{line_at(source, match.begin(0))} Fiber[#{match[1]}]"
    end
  end

  # Any assignment of `Thread.current` to a name, in any form: `t = Thread.current; t[:k]`, `(t = Thread.current)[:k]`,
  # `@t = Thread.current`, `def t = Thread.current`, a modifier `if`. An access through the thread is read by the scans
  # above, so the assignment is reported whatever follows it.
  def scan_alias_assignments(source, path, unresolved)
    offsets = []
    source.scan(/(?<![=!<>])=(?![=~>])[ \t]*Thread\.current\b(?![\[.])/) { offsets << Regexp.last_match.begin(0) }
    offsets.each do |offset|
      next if alias_allowed?(source, path, offset, offsets.size)

      unresolved << "#{path}:#{line_at(source, offset)} Thread.current alias"
    end
  end

  def alias_allowed?(source, path, offset, count)
    alias_allowlist.any? do |file, rule|
      path.end_with?(file) && count == 1 && line_text(source, offset).strip == rule[:line] &&
        source[0...offset].scan(/^[ \t]*def (?:self\.)?(\w+)/).last&.first == rule[:in_def]
    end
  end

  def line_text(source, offset)
    start = (source.rindex("\n", offset) || -1) + 1
    source[start...(source.index("\n", offset) || source.length)]
  end

  # A `*_KEY` constant without a `rigor` symbol is a key only where the file reads it directly. In a file that reads a
  # key through a local variable, one it does not read directly is read through that variable, so it is unresolved,
  # unless {declared_hash_key_constants} declares it as something other than a thread key.
  def scan_unread_key_constants(source, path, unresolved, constants, direct)
    constants.each do |name, symbol|
      next unless name.end_with?("_KEY") && !symbol.include?("rigor") && !direct.include?(name)
      next if declared_hash_key_constants.any? { |file, names| path.end_with?(file) && names.key?(name) }

      unresolved << "#{path}:#{line_at(source, source.index(/^[ \t]*#{name} = /))} #{name}"
    end
  end

  # The `*_KEY` constants a file uses for something other than a thread key, such as a Hash key, keyed by file and then
  # by constant name, each with why. The sibling of {not_run_scoped}: a name listed here is not reported as read through
  # a variable in that file. Empty today.
  def declared_hash_key_constants = {}

  def line_at(source, offset) = source[0...offset].count("\n") + 1

  # A memo slot a new owner adds is caught here even when no fixture fills it.
  it "registers every per-thread key in lib/ that is not a listed frame slot" do
    keys, unresolved = thread_keys_in_lib

    expect(unresolved).to be_empty
    unlisted = keys.keys - described_class.keys - not_run_scoped.keys
    expect(unlisted.to_h { |key| [key, keys[key]] }).to be_empty
    expect(described_class.keys - keys.keys).to be_empty
    expect(not_run_scoped.keys - keys.keys).to be_empty
    expect(not_run_scoped.keys & described_class.keys).to be_empty
  end

  # #2458: the two shapes the scan used to drop, a trailing comment on the constant and a key spelled without `rigor`.
  it "finds a per-thread key whose constant has a trailing comment or whose symbol has no `rigor`" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      EXTRA_MEMO_KEY = :__rigor_extra_probe_memo__ # per-run memo
      VOID_TAIL_MEMO_KEY = :__void_tail_extra_memo__
      def probe = [Thread.current[EXTRA_MEMO_KEY], Thread.current[VOID_TAIL_MEMO_KEY]]
      def literal = Thread.current[:__void_literal_memo__]
    RUBY

    expect(keys.keys).to contain_exactly(:__rigor_extra_probe_memo__, :__void_tail_extra_memo__, :__void_literal_memo__)
    expect(unresolved).to be_empty
  end

  it "reports a per-thread access whose constant the file does not define" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      def probe = Thread.current[Elsewhere::MISSING_KEY]
    RUBY

    expect(keys).to be_empty
    expect(unresolved).to eq(["fixture.rb:1 MISSING_KEY"])
  end

  # #2572 class 1: access shapes other than `Thread.current[` and `thread_variable_get(`. The symbol keys register;
  # `Fiber[`, and an alias line that assigns `Thread.current` to a local, are unresolved.
  it "finds a per-thread access in a shape the scan did not read" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      def bare = Thread.current.thread_variable_get :__shape_bare_probe__
      def fetched = Thread.current.fetch(:__shape_fetch_probe__, nil)
      def tested = Thread.current.key?(:__shape_key_probe__)
      def stored = Thread.current.store(:__shape_store_probe__, 1)
      def fiber = Fiber[:__shape_fiber_probe__]
      def alias_reader
        thread = Thread.current
        thread[:__shape_alias_probe__]
      end
    RUBY

    expect(keys.keys).to contain_exactly(:__shape_bare_probe__, :__shape_fetch_probe__, :__shape_key_probe__,
                                         :__shape_store_probe__)
    expect(unresolved).to contain_exactly("fixture.rb:5 Fiber[:__shape_fiber_probe__]",
                                          "fixture.rb:7 Thread.current alias")
  end

  # #2572 class 2: a key literal outside the symbol token class is unresolved, never dropped.
  it "reports a per-thread key written as a quoted symbol, a string or a top-level constant" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      def quoted = Thread.current[:"__quoted_probe__"]
      def string = Thread.current["__string_probe__"]
      def top = Thread.current[::TOP_PROBE_KEY]
    RUBY

    expect(keys).to be_empty
    expect(unresolved).to eq(["fixture.rb:1 :\"__quoted_probe__\"", "fixture.rb:2 \"__string_probe__\"",
                              "fixture.rb:3 TOP_PROBE_KEY"])
  end

  # #2572 class 3: a non-rigor `*_KEY` constant the file never reads as a direct thread key is read through a variable,
  # which the scan cannot follow, so it is unresolved.
  it "reports a non-rigor key constant that is read only through a variable" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      A_PROBE_KEY = :__void_probe_a__
      B_PROBE_KEY = :__void_probe_b__
      def sweep = [A_PROBE_KEY, B_PROBE_KEY].each { |k| Thread.current[k] }
    RUBY

    expect(keys).to be_empty
    expect(unresolved).to eq(["fixture.rb:1 A_PROBE_KEY", "fixture.rb:2 B_PROBE_KEY"])
  end

  # #2572 class 4: a namespaced constant is never resolved to the file's own constant of the same name, and a
  # mixed-case constant is reported whole.
  it "does not resolve a namespaced constant to the file's own, and reports a mixed-case constant whole" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      OWN_KEY = :rigor_own_probe
      def other = Thread.current[Other::OWN_KEY]
      def mixed = Thread.current[Mixed_Probe_KEY]
    RUBY

    expect(keys.keys).to eq([:rigor_own_probe])
    expect(unresolved).to eq(["fixture.rb:2 OWN_KEY", "fixture.rb:3 Mixed_Probe_KEY"])
  end

  # #2572 class 1, the alias: an assignment of `Thread.current` is reported in any form, not only at end of line.
  it "reports a Thread.current assignment in every form, not only a whole line" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      def semi
        t = Thread.current; t[:__semi_probe__]
      end
      def paren = (u = Thread.current)[:__paren_probe__]
      @ivar = Thread.current
      def thread = Thread.current
      def modified
        v = Thread.current if ready?
      end
    RUBY

    expect(keys).to be_empty
    expect(unresolved).to contain_exactly("fixture.rb:2 Thread.current alias", "fixture.rb:4 Thread.current alias",
                                          "fixture.rb:5 Thread.current alias", "fixture.rb:6 Thread.current alias",
                                          "fixture.rb:8 Thread.current alias")
  end

  # #2572 class 3's escape hatch: a `*_KEY` constant the file declares as something other than a thread key is not
  # reported, and nothing else in the file is excused by it.
  it "accepts a *_KEY constant that is declared as something other than a thread key" do
    hatch = { "fixture.rb" => { "A_PROBE_KEY" => "a Hash key, not a thread key" } }
    allow(self).to receive(:declared_hash_key_constants).and_return(hatch)
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      A_PROBE_KEY = :__void_probe_a__
      B_PROBE_KEY = :__void_probe_b__
      def sweep = [A_PROBE_KEY, B_PROBE_KEY].each { |k| Thread.current[k] }
    RUBY

    expect(unresolved).to eq(["fixture.rb:2 B_PROBE_KEY"])
  end

  # #2572: the registry's one allowed alias is pinned to `thread = Thread.current` inside `def self.release`, and
  # nothing else in the registry is excused by the allowlist.
  def registry_aliases(source)
    keys = {}
    unresolved = []
    scan_thread_keys(source, "lib/rigor/run_scoped_slots.rb", keys, unresolved)
    unresolved
  end

  it "allows the registry's alias only as the assignment inside release" do
    expect(registry_aliases(<<~RUBY)).to be_empty
      def self.release
        thread = Thread.current
        thread[:x] = nil
      end
    RUBY
    expect(registry_aliases(<<~RUBY)).to eq(["lib/rigor/run_scoped_slots.rb:2 Thread.current alias"])
      def self.release
        other = Thread.current
        other[:x] = nil
      end
    RUBY
    expect(registry_aliases(<<~RUBY)).to eq(["lib/rigor/run_scoped_slots.rb:2 Thread.current alias"])
      def self.other
        thread = Thread.current
      end
    RUBY
  end

  it "reports every alias in the registry when there is more than one" do
    both = <<~RUBY
      def self.release
        thread = Thread.current
      end
      def self.other
        thread = Thread.current
      end
    RUBY

    expect(registry_aliases(both)).to eq(["lib/rigor/run_scoped_slots.rb:2 Thread.current alias",
                                          "lib/rigor/run_scoped_slots.rb:5 Thread.current alias"])
  end

  # #2572 nit: a trailing comment names no access, so an access it spells out is not read.
  it "does not read a per-thread access that only a real trailing comment spells out" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      def probe = 1 # Thread.current[:__commented_probe__]
      x = 1 # Thread.current[:k]
    RUBY

    expect(keys).to be_empty
    expect(unresolved).to be_empty
  end

  # A `#` inside a string or a regexp is not a comment, so it hides no access on its line.
  it "does not drop an access that follows a # inside a string or a regexp" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      warn "see #2572"; Thread.current[:__void_h3__] = 1
      re = / #/; Thread.current[UNDEFINED_KEY]
      puts "x #y"; t = Thread.current
    RUBY

    expect(keys.keys).to eq([:__void_h3__])
    expect(unresolved).to eq(["fixture.rb:2 UNDEFINED_KEY", "fixture.rb:3 Thread.current alias"])
  end

  # A comparison of `Thread.current` is not an assignment of it; a default value is one.
  it "reports an assignment of Thread.current but not a comparison with it" do
    keys = {}
    unresolved = []
    scan_thread_keys(<<~RUBY, "fixture.rb", keys, unresolved)
      def same(t) = t == Thread.current
      def differs(owner) = owner != Thread.current
      def ordered(x) = x <= Thread.current
      def f(t = Thread.current) = t
    RUBY

    expect(keys).to be_empty
    expect(unresolved).to eq(["fixture.rb:4 Thread.current alias"])
  end

  it "registers a key once and hands it back" do
    registered = described_class.instance_variable_get(:@keys)
    described_class.instance_variable_set(:@keys, registered.dup)

    expect(2.times.map { described_class.register(:rigor_run_scoped_slots_probe) })
      .to eq(%i[rigor_run_scoped_slots_probe rigor_run_scoped_slots_probe])
    expect(described_class.keys.count(:rigor_run_scoped_slots_probe)).to eq(1)
  ensure
    described_class.instance_variable_set(:@keys, registered)
  end
end
