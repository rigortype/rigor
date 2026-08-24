# frozen_string_literal: true

module Rigor
  class CLI
    # The value `EffectsCommand` assembles and `EffectsRenderer` prints — one row per effect unit, already
    # projected out of {Rigor::Effects::EffectTable} so the renderer never touches an engine value.
    #
    # Rows are sorted by key and every collection inside one is sorted, so two runs over the same tree
    # print byte-identical output whether analysis ran sequentially or across the fork pool.
    class EffectsReport < Data.define(:rows, :full, :totals)
      # `totals:` defaults so a caller that builds a report by hand keeps working.
      def initialize(totals: nil, **rest)
        super
      end

      # One method's line in the report.
      #
      # `effects` is the transitive proven lane — this method's labels joined with every project method it
      # reaches. `exhaustive` false reads "these effects, and possibly more", and `causes` says why.
      # `direct` is what this method's own body contributed, per origin, which is the attributable half a
      # snapshot records (#381).
      #
      # `declared` is the `≤` lane, transitive like `effects`: what a source Rigor trusts but did not
      # verify *claims* this method reaches — today the project's `effects.attribution:` table (#385). It
      # is printed apart from `effects` and never folded into it, because the two answer different
      # questions: one is proven, the other is asserted. A declared label the proven lane already admits
      # is dropped here, where output is rendered; the table keeps both lanes raw.
      class Row < Data.define(:key, :effects, :declared, :exhaustive, :causes, :direct, :attribution)
        # `attribution:` defaults so a caller that builds a row by hand keeps working.
        def initialize(attribution: {}, **rest)
          super
        end

        def exhaustive?
          exhaustive
        end

        # The reading `--pure` selects and the default report omits: nothing proven beyond what every
        # envelope tolerates, nothing claimed, and no "possibly more".
        def pure?
          exhaustive && declared.empty? && (effects - TRIVIAL).empty?
        end

        # `mutate.local` is mutation of objects the frame allocated and never let out, which every
        # envelope tolerates — so a method proving only it is what `%a{pure}` means here.
        TRIVIAL = ["mutate.local"].freeze
        private_constant :TRIVIAL

        def carries_label?(labels)
          labels.any? { |label| (effects + declared).any? { |own| own == label || own.start_with?("#{label}.") } }
        end
      end

      # The counts the footer prints and the JSON payload carries (#434). The two lanes are counted
      # **separately** and deliberately: a declared label can never fail a build ([ADR-103](../adr/103-effect-labels.md)
      # § WD17), and on a Rails application it is most of the mass — 709 `io.db.read` plus 644
      # `io.db.write` on Redmine's 4,234 rows against zero of either proven. A single total tells a reader
      # how big the report is; the split tells them which half is a policy surface and which half is a
      # record whose diff they should be reviewing instead.
      Totals = Data.define(:units, :printed, :omitted, :unselected, :proven, :declared, :exhaustive,
                           :truncated)

      # Builds a report from an effect table. `full:` keeps the rows the report otherwise omits — an
      # exhaustive method proving nothing beyond `mutate.local`, which is the reading of `%a{pure}`.
      #
      # `scope:` selects which units are **printed** and never which are analysed (#439). A path argument
      # used to narrow the analysis, and a summary is transitive over whatever was analysed, so the
      # narrowed run answered `[] …?` for a method the whole-project run answered four labels for — with
      # nothing distinguishing that from a method which genuinely does nothing. `sources:` is
      # `Runner#effect_sources`, `{ "Class#m" => [path, …] }`, which is how a key is traced back to the
      # file it was written in.
      def self.build(table, full: false, sources: nil, scope: [], label: [], pure: false, limit: nil)
        roots = normalize_scope(scope)
        in_scope = table.filter_map do |entry|
          row_for(entry) if roots.empty? || in_scope?(entry.key, sources, roots)
        end
        selected = in_scope.select { |row| keep?(row, full: full, label: label, pure: pure) }
        new(rows: (limit ? selected.first(limit) : selected).freeze, full: full,
            totals: totals_for(table, in_scope, selected, limit, query: pure || !label.empty?))
      end

      # What the default report drops, and why each is a separate question:
      #
      # - **`full:`** keeps a row the omission rule would drop. Two shapes qualify: a method proving
      #   nothing beyond `mutate.local` and claiming nothing (the reading of `%a{pure}`), and a row with
      #   no label in **either** lane, which is 35–38 % of a real application's rows and says literally
      #   nothing — it exists only to record that something was unresolved, which the footer counts.
      # - **`pure:`** is the complement of the first: exactly the rows the default omits for being
      #   provably harmless, which is the set worth annotating and which nothing could ask for (#457).
      # - **`label:`** is the question chapter 19 opens with. It matches **either** lane, because "which
      #   controllers reach the network" is a question about the code and not about which lane knows it;
      #   the row's own rendering keeps the two apart.
      def self.keep?(row, full:, label:, pure:)
        return row.pure? if pure
        return row.carries_label?(label) unless label.empty?
        return true if full

        !row.pure? && !(row.effects.empty? && row.declared.empty?)
      end
      private_class_method :keep?

      # Two ways a row can be missing, and only one of them `--full` answers: the **omission rule** drops
      # a row that says nothing, and a **filter** — a path, `--label`, `--pure` — drops one that did not
      # match. Telling a `--label io.net` reader that 4,678 more are behind `--full` would be false, so
      # the two are counted apart.
      def self.totals_for(table, in_scope, selected, limit, query:)
        omitted = query ? 0 : in_scope.length - selected.length
        Totals.new(
          units: table.size, printed: limit ? [selected.length, limit].min : selected.length,
          omitted: omitted, unselected: table.size - selected.length - omitted,
          proven: selected.count { |row| !row.effects.empty? },
          declared: selected.count { |row| !row.declared.empty? },
          exhaustive: selected.count(&:exhaustive?),
          truncated: limit ? [selected.length - limit, 0].max : 0
        )
      end
      private_class_method :totals_for

      # A path argument may name a file or a directory, and either may be written relative or absolute —
      # so both sides are expanded and a directory matches by prefix. Deliberately not the `reach:` glob
      # syntax: this is the argument a shell just tab-completed, and `rigor effects app/models` meaning
      # "that directory" is the only reading a reader would guess.
      def self.normalize_scope(scope)
        Array(scope).map { |path| File.expand_path(path.to_s.chomp("/")) }.freeze
      end
      private_class_method :normalize_scope

      def self.in_scope?(key, sources, roots)
        paths = sources && sources[key]
        return false if paths.nil? || paths.empty?

        paths.any? do |path|
          absolute = File.expand_path(path)
          roots.any? { |root| absolute == root || absolute.start_with?("#{root}/") }
        end
      end
      private_class_method :in_scope?

      def self.row_for(entry)
        Row.new(
          key: entry.key,
          effects: entry.proven.to_a,
          declared: entry.rendered_declared.to_a,
          exhaustive: entry.exhaustive?,
          causes: entry.causes,
          direct: entry.direct.bundles.to_h { |origin, labels| [origin.to_s, labels.to_a] }.freeze,
          # The declared lane's provenance (#434). A *discharging* plugin row leaves no cause line by
          # design — WD6: a row the engine bundles is trusted, so it does not taint — which is why
          # `plugin-attribution` appeared zero times in a whole Redmine run while 1,320 rows carried a
          # `≤` clause. The origins are where the answer actually lives, and this is the direct half; a
          # label that arrived transitively is `rigor effects explain`'s question.
          attribution: entry.direct.declared_bundles.to_h { |origin, labels| [origin.to_s, labels.to_a] }
                            .freeze
        )
      end
      private_class_method :row_for

      def empty?
        rows.empty?
      end
    end
  end
end
