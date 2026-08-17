# frozen_string_literal: true

module Rigor
  class CLI
    # The value `EffectsCommand` assembles and `EffectsRenderer` prints — one row per effect unit, already
    # projected out of {Rigor::Effects::EffectTable} so the renderer never touches an engine value.
    #
    # Rows are sorted by key and every collection inside one is sorted, so two runs over the same tree
    # print byte-identical output whether analysis ran sequentially or across the fork pool.
    class EffectsReport < Data.define(:rows, :full)
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
      class Row < Data.define(:key, :effects, :declared, :exhaustive, :causes, :direct)
        def exhaustive?
          exhaustive
        end
      end

      # Builds a report from an effect table. `full:` keeps the rows the report otherwise omits — an
      # exhaustive method proving nothing beyond `mutate.local`, which is the reading of `%a{pure}`.
      def self.build(table, full: false)
        rows = table.filter_map { |entry| row_for(entry) unless !full && entry.trivial? }
        new(rows: rows.freeze, full: full)
      end

      def self.row_for(entry)
        Row.new(
          key: entry.key,
          effects: entry.proven.to_a,
          declared: entry.rendered_declared.to_a,
          exhaustive: entry.exhaustive?,
          causes: entry.causes,
          direct: entry.direct.bundles.to_h { |origin, labels| [origin.to_s, labels.to_a] }.freeze
        )
      end
      private_class_method :row_for

      def empty?
        rows.empty?
      end
    end
  end
end
