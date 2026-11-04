# frozen_string_literal: true

# SHADOW=1 on top of MEMO=3 (measurement only): every hit also recomputes the node with the memo suspended,
# compares the fresh answer with the stored one, and compares the fresh computation's advisory-table writes
# with the stored write list. The recompute's writes replace the replay; the stored value is returned, so the
# run's output is still the live memo's. A mismatch is a key that is not complete.
module WC3
  SHADOW_EX = []
  SHADOW_WEX = []
  SHADOW_SEX = []
  SLST = singleton_class::LST
  @suspend = 0

  ABSENT = Object.new.freeze
  TABLE_IVAR = { record_dynamic_origin: :@dynamic_origins, record_void_origin: :@void_origins,
                 record_plugin_typed_call: :@plugin_typed_calls, record_optimistic_origin: :@optimistic_origins }.freeze
  @prior = nil

  class << self
    def note_prior(table, node)
      return if @prior.nil?

      h = (@prior[table] ||= {}.compare_by_identity)
      h[node] = table.key?(node) ? table[node] : ABSENT unless h.key?(node)
    end

    # Whether replaying `stored` would leave the four tables as the recompute left them: for every key either
    # list touched, the replay's last value (or, for a key only the recompute wrote, its value before the
    # recompute) against the table's value now.
    def state_mismatch(stored, prior)
      replay = {}.compare_by_identity
      (stored || []).each do |t, m, x|
        tb = t.instance_variable_get(TABLE_IVAR[m])
        (replay[tb] ||= {}.compare_by_identity)[x[0]] = m == :record_plugin_typed_call ? true : x[1]
      end
      bad = []
      replay.each do |tb, h|
        h.each do |n, v|
          now = tb.key?(n) ? tb[n] : ABSENT
          bad << [n, v, now] unless now.equal?(v) || now == v
        end
      end
      prior.each do |tb, h|
        h.each do |n, before|
          next if replay[tb]&.key?(n)

          now = tb.key?(n) ? tb[n] : ABSENT
          bad << [n, before, now] unless now.equal?(before) || now == before
        end
      end
      bad
    end

    def writes_equal?(a, b)
      a ||= []
      b ||= []
      return false unless a.size == b.size

      a.each_with_index.all? do |(t1, m1, x1), i|
        t2, m2, x2 = b[i]
        t1.equal?(t2) && m1 == m2 && x1.size == x2.size && x1.each_with_index.all? do |v, k|
          v.equal?(x2[k]) || v == x2[k]
        end
      end
    end

    def short(type)
      type.respond_to?(:describe) ? type.describe(:short).to_s[0, 160] : type.inspect[0, 160]
    rescue StandardError => e
      "<describe failed: #{e.class}>"
    end
  end

  singleton_class.prepend(Module.new do
    def live(scope, node)
      return yield if @suspend.positive?

      ph = PHASE_OF[WC.top]
      st = SLST[ph]
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
          @suspend += 1
          @prior = {}.compare_by_identity
          open_capture
          begin
            fresh = yield
          ensure
            close_capture
            @suspend -= 1
            prior = @prior
            @prior = nil
          end
          bad = state_mismatch(e[2], prior)
          unless bad.empty?
            st[:shadow_table_state_mismatch] += 1
            if SHADOW_SEX.size < 60
              SHADOW_SEX << { phase: ph, node: node.class.name.delete_prefix("Prism::"), path: scope.source_path.to_s,
                              line: node.location.start_line,
                              diffs: bad.first(4).map { |n, v, now| ["#{n.class.name.delete_prefix('Prism::')}@#{n.location.start_line}", v.equal?(ABSENT) ? 'ABSENT' : v.inspect[0, 80], now.equal?(ABSENT) ? 'ABSENT' : now.inspect[0, 80]] } }
            end
          end
          flags = ANY ? @lfa : @lfe
          st[:shadow_checked] += 1
          st[:shadow_recompute_refused] += 1 unless flags.zero?
          st[:shadow_id_changed] += 1 unless id == (ELIDE ? @id2 : @id)
          unless fresh == e[1]
            st[:shadow_mismatch] += 1
            a = short(e[1])
            b = short(fresh)
            st[:shadow_mismatch_describe] += 1 unless a == b
            if SHADOW_EX.size < 300
              SHADOW_EX << { phase: ph, node: node.class.name.delete_prefix("Prism::"), path: scope.source_path.to_s,
                             line: node.location.start_line, stored: a, fresh: b, describe_equal: a == b }
            end
          end
          unless writes_equal?(e[2], @lw)
            st[:shadow_write_list_differs] += 1
            if SHADOW_WEX.size < 60
              fmt = lambda do |ws|
                (ws || []).map { |t, m, x| "#{m}(#{x.map { |v| v.is_a?(Prism::Node) ? "#{v.class.name.delete_prefix('Prism::')}@#{v.location.start_line}" : v.inspect[0, 60] }.join(', ')})#{t.equal?(scope) ? '' : '[other scope]'}" }
              end
              SHADOW_WEX << { phase: ph, node: node.class.name.delete_prefix("Prism::"), path: scope.source_path.to_s,
                              line: node.location.start_line, stored: fmt.call(e[2]), fresh: fmt.call(@lw) }
            end
          end
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
      super.merge(shadow_examples: SHADOW_EX, shadow_write_examples: SHADOW_WEX, shadow_state_examples: SHADOW_SEX)
    end
  end)
end

Rigor::Scope.prepend(Module.new do
  def record_dynamic_origin(node, cause)
    WC3.note_prior(@dynamic_origins, node)
    super
  end

  def record_void_origin(node, origin)
    WC3.note_prior(@void_origins, node)
    super
  end

  def record_plugin_typed_call(node)
    WC3.note_prior(@plugin_typed_calls, node)
    super
  end

  def record_optimistic_origin(node, cause)
    WC3.note_prior(@optimistic_origins, node)
    super
  end
end)
