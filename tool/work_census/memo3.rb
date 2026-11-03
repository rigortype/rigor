# frozen_string_literal: true

# ADR-129 option 3, stage 0b (measurement only, never product code). Loaded by work_census.rb when
# MEMO=3 (a live `type_of` memo keyed on (scope, node, state id)) or COUNT3=1 (count-only counters, no
# memo). Everything here is prepended onto the engine; nothing under lib/ changes.
#
# The state id is a harness-side integer. Every frame install takes a fresh id and restores the saved one
# on exit; every in-place resource write takes a fresh id. A frame whose body wrote a resource it does not
# own exits to a fresh id instead of its saved one (the resource changed under it). The owner of the ADR-55
# resources (the outermost user-method inference, where the guard stack is seeded and drained) restores its
# saved id at exit, because the drain resets every resource it owns. The guard walk (KeyPresenceGuard)
# owns its Walk the same way.
#
# REFUSE=escape (Opus): a computation is not stored when, during it, a sink push or a resource write
# targets a slot installed or owned outside it, or a transient / consult event is logged.
# REFUSE=any (Fable): a computation is not stored when it touched any sink, resource, event log, or the
# LoopValueRecord / inject one-slot caches at all.
#
# MEMO_PHASES=rule,main,callee picks the phases (the harness's WC.top attribution) whose type_of calls
# look up and store. LEAF=1 stores leaf reads; LEAF=0 (default) skips them.

module WC3
  LIVE = ENV["MEMO"] == "3"
  COUNT = ENV["COUNT3"] == "1"
  ANY = ENV.fetch("REFUSE", "escape") == "any"
  LEAF = ENV["LEAF"] == "1"
  ELIDE = ENV["ELIDE"] == "1"
  OPEN = ENV.fetch("MEMO_PHASES", "rule,main,callee").split(",").to_h { |p| [p.strip.to_sym, true] }

  SINK = 1
  RES = 2
  EV_ESC = 4   # event while the owner is outside the computation (or no owner)
  EV_INT = 8   # event while the owner is inside the computation
  SLOT = 16    # LoopValueRecord / inject one-slot cache write ('any' only)
  WALK_RES = 32 # KeyPresenceGuard walk mutation
  BITS = { sink: SINK, resource: RES, event_escaping: EV_ESC, event_internal: EV_INT, slot: SLOT,
           walk: WALK_RES }.freeze

  LEAF_CLASSES = %w[
    LocalVariableReadNode InstanceVariableReadNode ClassVariableReadNode GlobalVariableReadNode SelfNode
    IntegerNode FloatNode RationalNode ImaginaryNode StringNode SymbolNode NilNode TrueNode FalseNode
    RegularExpressionNode SourceFileNode SourceLineNode SourceEncodingNode ConstantReadNode ConstantPathNode
    NumberedReferenceReadNode BackReferenceReadNode
  ].to_h { |n| [Prism.const_get(n), true] }.freeze

  PHASE_OF = Hash.new do |h, k|
    h[k] = if k.start_with?("callee_body") then :callee
           elsif k.start_with?("rules") then :rule
           elsif k.start_with?("index") then :main
           else :other
           end
  end

  @id = 0
  @id2 = 0
  @nid = 0
  @seq = 0
  @epoch = 0      # inference resources (guard stack, fuel, summaries)
  @wepoch = 0     # the guard walk's Walk
  @nep = 0
  @owner_seq = nil
  # open captures, as parallel stacks: start seq, escape flags, any flags, writes (nil until one happens)
  @cs = []
  @fe = []
  @fa = []
  @cw = []
  INST = { return: [], next: [], break: [], break_value: [] }.freeze
  RETRY = []  # [edge, seq]
  WALK = []   # seq of the installed Walk, nil for without_guards
  ST = Hash.new(0)
  @table = {}.compare_by_identity

  class << self
    attr_reader :id, :id2, :seq, :owner_seq, :lfe, :lfa, :lw

    # A frame install: a fresh id. `id2` stays when `elide` says the value installed is identical to the one
    # it shadows (the equal-value elision variant). Exit restores both, unless a resource the frame does not
    # own changed inside it.
    def frame(elide = false)
      sid = @id
      sid2 = @id2
      se = @epoch
      sw = @wepoch
      s = (@seq += 1)
      @id = (@nid += 1)
      if elide
        ST[:frame_installs_elided] += 1
      else
        @id2 = @id
      end
      ST[:frame_installs] += 1
      yield s
    ensure
      if se == @epoch && sw == @wepoch
        @id = sid
        @id2 = sid2
      else
        @id = @id2 = (@nid += 1)
      end
    end

    def sink_frame(key, installs_value = true, elide = false)
      frame(elide) do |s|
        st = INST[key]
        st.push(installs_value ? s : nil)
        begin
          yield
        ensure
          st.pop
        end
      end
    end

    def nil_sinks_frame(elide)
      frame(elide) do
        INST.each_value { |st| st.push(nil) }
        RETRY.push(nil)
        begin
          yield
        ensure
          INST.each_value(&:pop)
          RETRY.pop
        end
      end
    end

    def retry_frame(edge)
      frame do |s|
        RETRY.push([edge, s])
        begin
          yield
        ensure
          RETRY.pop
        end
      end
    end

    # The outermost user-method inference: owns the ADR-55 resources and drains them on exit.
    def owner
      sid = @id
      sid2 = @id2
      se = @epoch
      sw = @wepoch
      so = @owner_seq
      @owner_seq = (@seq += 1)
      ST[:owners] += 1
      yield
    ensure
      @epoch = se
      @owner_seq = so
      if sw == @wepoch
        @id = sid
        @id2 = sid2
      else
        @id = @id2 = (@nid += 1)
      end
    end

    # KeyPresenceGuard.with_guards: a frame that also owns the Walk it installs.
    def walk_frame
      sid = @id
      sid2 = @id2
      se = @epoch
      sw = @wepoch
      s = (@seq += 1)
      @id = @id2 = (@nid += 1)
      WALK.push(s)
      ST[:frame_installs] += 1
      yield
    ensure
      WALK.pop
      @wepoch = sw
      if se == @epoch
        @id = sid
        @id2 = sid2
      else
        @id = @id2 = (@nid += 1)
      end
    end

    def unwalk_frame(elide)
      frame(elide) do
        WALK.push(nil)
        begin
          yield
        ensure
          WALK.pop
        end
      end
    end

    def mark(slot_seq, bit)
      i = @cs.size - 1
      while i >= 0
        @fa[i] |= bit
        @fe[i] |= bit if @cs[i] >= slot_seq
        i -= 1
      end
    end

    def res_write
      ST[:res_writes] += 1
      @epoch = (@nep += 1)
      @id = @id2 = (@nid += 1)
      mark(@owner_seq || 0, RES)
    end

    def walk_write
      ST[:walk_writes] += 1
      @wepoch = (@nep += 1)
      @id = @id2 = (@nid += 1)
      mark(WALK.last || 0, WALK_RES)
    end

    def event
      ST[:events] += 1
      o = @owner_seq
      i = @cs.size - 1
      while i >= 0
        @fa[i] |= EV_ESC
        @fe[i] |= o && o > @cs[i] ? EV_INT : EV_ESC
        i -= 1
      end
    end

    def sink_push(key)
      ST[:sink_pushes] += 1
      s = INST[key].last
      ST[:sink_push_unknown] += 1 if s.nil?
      mark(s || 0, SINK)
    end

    def retry_push(frames, stmt)
      min = nil
      RETRY.each do |pair|
        next if pair.nil?

        edge, s = pair
        next unless frames.include?(edge) && edge.frame.include?(stmt)

        min = s if min.nil? || s < min
      end
      return if min.nil?

      ST[:sink_pushes] += 1
      mark(min, SINK)
    end

    def slot_write
      ST[:slot_writes] += 1
      i = @cs.size - 1
      while i >= 0
        @fa[i] |= SLOT
        i -= 1
      end
    end

    def note_write(scope, writer, args)
      top = @cw.size - 1
      return if top.negative?

      (@cw[top] ||= []) << [scope, writer, args]
    end

    def open_capture
      @cs.push(@seq)
      @fe.push(0)
      @fa.push(0)
      @cw.push(nil)
    end

    # Pops the innermost capture and hands its writes to the parent capture; the popped flags and writes are
    # left in lfe / lfa / lw (no allocation).
    def close_capture
      w = @cw.pop
      @lfe = @fe.pop
      @lfa = @fa.pop
      @cs.pop
      if w && (top = @cw.size - 1) >= 0
        (@cw[top] ||= []).concat(w)
      end
      @lw = w
      nil
    end

    CLAUSE_KEYS = %i[rigor_return_sink rigor_next_sink rigor_break_sink rigor_break_value_sink
                     rigor_retry_frames].freeze

    def clause_sinks_nil?
      t = Thread.current
      CLAUSE_KEYS.all? { |k| t[k].nil? }
    end

    def clear_file!
      @table = {}.compare_by_identity
      Count.clear_file! if COUNT
      ST[:files] += 1
      ST[:open_captures_at_file_end] += @cs.size
    end

    def bypass?(typer_operand_types, typer_tracer, node)
      typer_operand_types || typer_tracer || !node.is_a?(Prism::Node) ||
        Rigor::Inference::FlowTracer.active? || Rigor::Analysis::DependencyRecorder.active?
    end

    # ---- live memo (MEMO=3) ----
    LST = Hash.new { |h, k| h[k] = Hash.new(0) }

    def live(scope, node)
      ph = PHASE_OF[WC.top]
      st = LST[ph]
      st[:calls] += 1
      unless OPEN[ph]
        st[:closed] += 1
        return yield
      end
      if !LEAF && LEAF_CLASSES[node.class]
        st[:leaf_skipped] += 1
        return yield
      end

      id = ELIDE ? @id2 : @id
      per = (@table[scope] ||= {}.compare_by_identity)
      e = per[node]
      while e
        if e[0] == id
          st[:hits] += 1
          e[2]&.each { |target, writer, args| target.public_send(writer, *args) }
          return e[1]
        end
        e = e[3]
      end
      st[:misses] += 1
      open_capture
      begin
        result = yield
      ensure
        close_capture
      end
      flags = ANY ? @lfa : @lfe
      w = @lw
      if flags.zero?
        per[node] = [id, result, w&.freeze, per[node]]
        st[:stores] += 1
        st[:stored_writes] += w.size if w
      else
        st[:refused] += 1
        BITS.each { |name, bit| st[:"refused_#{name}"] += 1 if flags.anybits?(bit) }
      end
      result
    end

    def report
      out = { config: { live: LIVE, count: COUNT, refuse: ANY ? "any" : "escape", leaf: LEAF, elide: ELIDE, phases: OPEN.keys },
              global: ST.dup }
      out[:live] = LST.transform_values(&:dup) if LIVE
      out[:count] = Count.report if COUNT
      out
    end
  end

  # ---- count-only counters (COUNT3=1): no memo, every call computed ----
  module Count
    MODES = %i[v1 id_esc id_any id2_esc id2_any vec_esc vec_any one_v1 one_id_esc one_id_any one_id2_esc
               one_vec_esc].freeze
    C = Hash.new { |h, k| h[k] = Hash.new(0) } # "phase/class" => counters
    SAVED = Hash.new { |h, k| h[k] = Hash.new(0.0) } # mode => "phase/class" => inclusive cpu of outermost hits
    XPH = Hash.new(0) # "mode:lookup<-store" => hits
    @depth = MODES.to_h { |m| [m, 0] }
    @k1 = {}.compare_by_identity
    @k3 = {}.compare_by_identity
    @kv = {}.compare_by_identity
    @k2 = {}.compare_by_identity
    @o2 = {}.compare_by_identity
    @o1 = {}.compare_by_identity
    @o3 = {}.compare_by_identity
    @ov = {}.compare_by_identity

    YIELD = :__rigor_yield_value_type__
    FWD = :__rigor_forwarded_call_arg_types__
    THR = :__rigor_threaded_block_body__
    REP = :__rigor_reflective_ivar_write_repeating__
    SINKS = %i[rigor_return_sink rigor_provisional_returns rigor_next_sink rigor_break_sink
               rigor_break_value_sink rigor_retry_frames].freeze
    KPG = :__rigor_key_presence_guard
    ACC = :__rigor_acceptance_unread_shape_refused__
    WRS = :__rigor_declared_param_writer_scope__
    UNE = :rigor_scope_index_unentered_evaluator
    FUEL = :__rigor_user_method_unroll_fuel__
    GUARD = :__rigor_user_method_inference_stack__

    class << self
      def clear_file!
        @k1 = {}.compare_by_identity
        @k3 = {}.compare_by_identity
        @kv = {}.compare_by_identity
        @k2 = {}.compare_by_identity
        @o2 = {}.compare_by_identity
        @o1 = {}.compare_by_identity
        @o3 = {}.compare_by_identity
        @ov = {}.compare_by_identity
      end

      def vector
        t = Thread.current
        walk = t[KPG]
        [t[YIELD].__id__, t[FWD].__id__, t[THR].__id__, t[REP].__id__,
         t[SINKS[0]].__id__, t[SINKS[1]].__id__, t[SINKS[2]].__id__, t[SINKS[3]].__id__, t[SINKS[4]].__id__,
         t[SINKS[5]].__id__, walk.__id__, walk ? walk.guard_ends.size : -1, t[ACC].__id__, t[WRS].__id__,
         t[UNE].__id__, Rigor::Inference::FlowTracer.active?, Rigor::Effects::Collector.active?,
         t[FUEL], t[GUARD]&.size || 0]
      end

      def cpu = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)

      # rubocop:disable Metrics
      def call(scope, node)
        ph = PHASE_OF[WC.top]
        cls = node.class.name.delete_prefix("Prism::")
        key = "#{ph}/#{cls}"
        c = C[key]
        c[:calls] += 1
        id = WC3.id
        id2 = WC3.id2
        vec = vector

        p1 = (@k1[scope] ||= {}.compare_by_identity)
        hits = {}
        hits[:v1] = p1.key?(node)
        e3 = ((@k3[scope] ||= {}.compare_by_identity)[node] ||= {})[id]
        ev = ((@kv[scope] ||= {}.compare_by_identity)[node] ||= {})[vec]
        e2 = ((@k2[scope] ||= {}.compare_by_identity)[node] ||= {})[id2]
        c[:id2_repeat_raw] += 1 if e2
        hits[:id2_esc] = e2 && e2[0]
        hits[:id2_any] = e2 && e2[1]
        s2 = @o2[node]
        hits[:one_id2_esc] = s2 && s2[0].equal?(scope) && s2[1] == id2
        c[:id_repeat_raw] += 1 if e3
        c[:vec_repeat_raw] += 1 if ev
        hits[:id_esc] = e3 && e3[0]
        hits[:id_any] = e3 && e3[1]
        hits[:vec_esc] = ev && ev[0]
        hits[:vec_any] = ev && ev[1]
        s1 = @o1[node]
        hits[:one_v1] = s1.equal?(scope)
        s3 = @o3[node]
        hits[:one_id_esc] = s3 && s3[0].equal?(scope) && s3[1] == id && s3[2]
        hits[:one_id_any] = s3 && s3[0].equal?(scope) && s3[1] == id && s3[3]
        sv = @ov[node]
        hits[:one_vec_esc] = sv && sv[0].equal?(scope) && sv[1] == vec

        outer = []
        MODES.each do |m|
          next unless hits[m]

          c[:"hit_#{m}"] += 1
          if @depth[m].zero?
            c[:"outer_hit_#{m}"] += 1
            outer << m
          end
          store_ph = case m
                     when :id_esc, :id_any then e3[2]
                     when :id2_esc, :id2_any then e2[2]
                     when :vec_esc, :vec_any then ev[2]
                     end
          XPH["#{m}:#{ph}<-#{store_ph}"] += 1 if store_ph
          @depth[m] += 1
        end

        t0 = cpu
        WC3.open_capture
        begin
          result = yield
        ensure
          WC3.close_capture
          fe = WC3.lfe
          fa = WC3.lfa
          dt = cpu - t0
          MODES.each { |m| @depth[m] -= 1 if hits[m] }
        end
        outer.each { |m| SAVED[m][key] += dt }

        p1[node] = true
        esc_ok = fe.zero?
        any_ok = fa.zero?
        c[:storable_esc] += 1 if esc_ok
        c[:storable_any] += 1 if any_ok
        BITS.each do |name, bit|
          c[:"refused_esc_#{name}"] += 1 if fe.anybits?(bit)
          c[:"refused_any_#{name}"] += 1 if fa.anybits?(bit)
        end
        c[:refused_esc_event_internal_only] += 1 if fe == EV_INT
        h3 = @k3[scope][node]
        if (x = h3[id])
          x[0] ||= esc_ok
          x[1] ||= any_ok
        else
          h3[id] = [esc_ok, any_ok, ph]
        end
        h2 = @k2[scope][node]
        if (x = h2[id2])
          x[0] ||= esc_ok
          x[1] ||= any_ok
        else
          h2[id2] = [esc_ok, any_ok, ph]
        end
        @o2[node] = [scope, id2] if esc_ok
        hv = @kv[scope][node]
        if (x = hv[vec])
          x[0] ||= esc_ok
          x[1] ||= any_ok
        else
          hv[vec] = [esc_ok, any_ok, ph]
        end
        @o1[node] = scope
        if esc_ok || any_ok
          prev = @o3[node]
          if prev && prev[0].equal?(scope) && prev[1] == id
            prev[2] ||= esc_ok
            prev[3] ||= any_ok
          else
            @o3[node] = [scope, id, esc_ok, any_ok]
          end
        end
        @ov[node] = [scope, vec] if esc_ok
        result
      end
      # rubocop:enable Metrics

      def report
        { by_phase_class: C.transform_values(&:dup), saved_cpu: SAVED.transform_values(&:dup), cross_phase: XPH.dup }
      end
    end
  end
end

# ---------------- hooks ----------------

Rigor::Analysis::Runner.prepend(Module.new do
  def analyze_file_body(*a, **k)
    super
  ensure
    WC3.clear_file!
  end
end)

Rigor::Inference::ExpressionTyper.prepend(Module.new do
  if WC3::LIVE
    def type_of(node)
      return super if WC3.bypass?(@operand_types, @tracer, node)

      WC3.live(scope, node) { super }
    end
  else
    def type_of(node)
      return super if WC3.bypass?(@operand_types, @tracer, node)

      WC3::Count.call(scope, node) { super }
    end
  end

  # frames
  def without_block_body_threading(*a, &b) = WC3.frame(Thread.current[:__rigor_threaded_block_body__] == true) { super }

  # owner and resources
  def compute_user_method_return(*)
    stack = Thread.current[:__rigor_user_method_inference_stack__]
    return super unless stack.nil? || stack.empty?

    WC3.owner { super }
  end

  def unroll_fuel_remaining(*)
    before = Thread.current[:__rigor_user_method_unroll_fuel__]
    r = super
    WC3.res_write unless Thread.current[:__rigor_user_method_unroll_fuel__].equal?(before)
    r
  end

  def evaluate_guarded_user_method_body(*)
    WC3.res_write # guard stack push
    begin
      super
    ensure
      WC3.res_write # guard stack pop
    end
  end

  def evaluate_body_with_returns(*)
    stack = Thread.current[:__rigor_user_method_inference_stack__]
    WC3.res_write if stack && !stack.empty? # the fixpoint's [:consulted] = false precedes each evaluation
    super
  end

  def seed_fixpoint_summary(*)
    r = super
    WC3.res_write
    r
  end

  def fixpoint_step(*)
    r = super
    WC3.res_write
    r
  end

  def degrade_entangled_fixpoint(*)
    r = super
    WC3.res_write
    r
  end

  def collapse_fixpoint_cap(*)
    r = super
    WC3.res_write
    r
  end

  def consult_summary(summaries, plain_signature)
    hit = summaries[plain_signature]
    r = super
    if hit
      WC3.res_write
      WC3.event
    end
    r
  end

  def note_transient_fallback(*)
    WC3.event
    super
  end

  def record_inject_accumulator(*)
    WC3.slot_write
    super
  end
end)

Rigor::Inference::ExpressionTyper.singleton_class.prepend(Module.new do
  def with_yield_value_type(type, &b) = WC3.frame(Thread.current[:__rigor_yield_value_type__].equal?(type)) { super }
  def with_forwarded_arg_types(types, &b) = WC3.frame(Thread.current[:__rigor_forwarded_call_arg_types__].equal?(types)) { super }
end)

Rigor::Inference::StatementEvaluator.singleton_class.prepend(Module.new do
  def with_return_sink(*a, &b) = WC3.sink_frame(:return) { super }
  def provisional_returns(*a, &b) = WC3.frame(Thread.current[:rigor_provisional_returns] == true) { super }
  def with_next_sink(*a, &b) = WC3.sink_frame(:next) { super }
  def with_break_value_sink(*a, &b) = WC3.sink_frame(:break_value) { super }
end)

Rigor::Inference::StatementEvaluator.prepend(Module.new do
  def collect_break_scopes(*a, &b) = WC3.sink_frame(:break) { super }

  def with_raise_frame(edge, &b)
    return super unless edge

    WC3.retry_frame(edge) { super }
  end

  def without_jump_sinks(*a, &b) = WC3.nil_sinks_frame(WC3.clause_sinks_nil?) { super }
  def without_return_sink(*a, &b) = WC3.sink_frame(:return, false, Thread.current[:rigor_return_sink].nil?) { super }
  def eval_def(*a) = WC3.sink_frame(:return, false, Thread.current[:rigor_return_sink].nil?) { super }

  def eval_return(*)
    WC3.sink_push(:return) if Thread.current[:rigor_return_sink]
    super
  end

  def eval_next(*)
    WC3.sink_push(:next) if Thread.current[:rigor_next_sink]
    super
  end

  def eval_break(*)
    WC3.sink_push(:break) if Thread.current[:rigor_break_sink]
    WC3.sink_push(:break_value) if Thread.current[:rigor_break_value_sink]
    super
  end

  def record_raise_points(frames, stmt, _stmt_scope)
    WC3.retry_push(frames, stmt)
    super
  end
end)

Rigor::Inference::ReflectiveIvarWrite.singleton_class.prepend(Module.new do
  def in_repeating_body(*a, &b) = WC3.frame { super }
end)

Rigor::Inference::KeyPresenceGuard.singleton_class.prepend(Module.new do
  def with_guards(*a, &b) = WC3.walk_frame { super }
  def without_guards(*a, &b) = WC3.unwalk_frame(Thread.current[:__rigor_key_presence_guard].nil?) { super }

  def record(*)
    r = super
    WC3.walk_write unless r.nil?
    r
  end
end)

Rigor::Inference::Acceptance.singleton_class.prepend(Module.new do
  def refusing_unread(kind, &b) = WC3.frame(Thread.current[:__rigor_acceptance_unread_shape_refused__].equal?(kind)) { super }
end)

Rigor::Inference::ScopeIndexer::DeclaredParamWrites.singleton_class.prepend(Module.new do
  def with_writer_scope(scope, &b)
    return super if scope.nil?

    WC3.frame { super }
  end
end)

Rigor::Inference::ScopeIndexer.singleton_class.prepend(Module.new do
  def with_unentered_evaluator(*a, &b) = WC3.frame { super }
end)

Rigor::Inference::FlowTracer.singleton_class.prepend(Module.new do
  def record(*a, &b) = WC3.frame { super }
end)

Rigor::Effects::Collector.singleton_class.prepend(Module.new do
  def collect_for(*a, **k, &b) = WC3.frame { super }
end)

Rigor::Inference::LoopValueRecord.singleton_class.prepend(Module.new do
  def conditional(*)
    WC3.slot_write
    super
  end
end)

Rigor::Scope.prepend(Module.new do
  def record_dynamic_origin(node, cause)
    WC3.note_write(self, :record_dynamic_origin, [node, cause])
    super
  end

  def record_void_origin(node, origin)
    WC3.note_write(self, :record_void_origin, [node, origin])
    super
  end

  def record_plugin_typed_call(node)
    WC3.note_write(self, :record_plugin_typed_call, [node])
    super
  end

  def record_optimistic_origin(node, cause)
    WC3.note_write(self, :record_optimistic_origin, [node, cause])
    super
  end
end)
