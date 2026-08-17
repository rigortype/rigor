# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # rigor-activerecord's effect contract (ADR-103 WD10; design note § 11.2; issue #387).
      #
      # ## The two channels, and which row goes where
      #
      # The plugin already ships `sig/active_record/relation.rbs`, so **every `ActiveRecord::Relation`
      # method it declares carries its own `%a{…}` annotation there** — the tier-1 channel, read as an
      # accepted signature and therefore discharging (ADR-103 WD6). That file is also where the builder /
      # materializer split lives, because it is the file that already draws it.
      #
      # What is left over lands here, and each item is left over for a reason RBS cannot fix:
      #
      # - **`ActiveRecord::Base`'s own surface.** The plugin ships no `ActiveRecord::Base` signature and
      #   should not: an app's models are typed from `db/schema.rb`, per project, and a generic base-class
      #   RBS would fight whatever the project's own `rbs collection` supplies.
      # - **The `Enumerable` delegations on a Relation.** `map`, `filter_map`, `each_with_object` and the
      #   rest materialise by delegating to `each`, and declaring them in the bundled RBS would change how
      #   they *type* (`Enumerable#map`'s block-return element type is the whole point of the include).
      # - **The connection adapter and the migration DSL**, neither of which the plugin types at all.
      #
      # ## Why the reads and writes are worth spelling out at all
      #
      # An `ActiveRecord::Base` row reaches `User.find` through the project's own
      # `User < ApplicationRecord < ActiveRecord::Base` lines, so one row covers every model in the app.
      # That is the whole economy of the framework layer: thirty-odd rows here colour the several thousand
      # database touches a Rails app performs, and none of them needed a line of application code.
      module Effects
        BASE = "ActiveRecord::Base"
        RELATION = "ActiveRecord::Relation"
        ADAPTER = "ActiveRecord::ConnectionAdapters::AbstractAdapter"
        MIGRATION = "ActiveRecord::Migration"

        READ = ["io.db.read"].freeze
        WRITE = ["io.db.write"].freeze
        TRANSACTION = ["io.db.transaction"].freeze
        SCHEMA_WRITE = ["io.db.write", "rails.schema.write"].freeze

        # Class-side finders. Every one issues a `SELECT` the moment it is called — that is what separates
        # them from `where`, which returns a relation and issues nothing.
        SINGLETON_READS = %w[
          find find_by find_by! first first! last last! take take! sole find_sole_by
          second third fourth fifth forty_two second_to_last third_to_last
          exists? any? none? one? many? empty? count sum average minimum maximum calculate
          pluck pick ids find_each find_in_batches in_batches find_by_sql count_by_sql
          find_or_initialize_by
        ].freeze

        # Class-side writers.
        SINGLETON_WRITES = %w[
          create create! insert insert! insert_all insert_all! upsert upsert_all
          update update! update_all delete delete_all delete_by destroy destroy_all destroy_by
          find_or_create_by find_or_create_by! create_or_find_by create_or_find_by! touch_all
        ].freeze

        # Instance-side readers. `reload` re-issues the `SELECT` and replaces the record's attributes,
        # which is a receiver mutation as well as a read.
        INSTANCE_READS = %w[valid? invalid? reload].freeze

        # Instance-side writers. Each is a statement issued now; `save`'s callbacks and validators are the
        # `effect_edges:` half, and arrive as edges rather than labels.
        INSTANCE_WRITES = %w[
          save save! update update! update_attribute update_attributes update_attributes!
          update_column update_columns destroy destroy! delete touch increment! decrement!
          toggle! becomes! insert
        ].freeze

        # The `Enumerable` surface a Relation inherits. Every one of these runs the query, because every
        # one of them calls `each`.
        RELATION_MATERIALIZERS = %w[
          map flat_map filter_map collect collect_concat select filter reject find detect find_all
          each_with_object each_with_index each_entry each_slice each_cons reduce inject
          group_by partition sort sort_by min min_by max max_by minmax tally zip
          take_while drop_while chunk_while slice_when lazy to_set to_h
          all? any? none? one? include? member? first count sum
        ].freeze

        # Raw SQL, narrowed by the statement's own leading verb ({Rigor::Effects::Narrowing} `sql_verb`).
        ADAPTER_SQL = %w[execute exec_query exec_insert exec_update exec_delete select_all select_one
                         select_value select_values select_rows query query_value query_values].freeze

        # The migration DSL. `rails.schema.write` is the meaning a reviewer names ("this changes the
        # schema"); `io.db.write` is the transport that makes the summary honest.
        MIGRATION_DSL = %w[
          create_table drop_table rename_table change_table create_join_table drop_join_table
          add_column remove_column rename_column change_column change_column_null
          change_column_default change_column_comment
          add_index remove_index rename_index add_reference remove_reference
          add_foreign_key remove_foreign_key add_check_constraint remove_check_constraint
          add_timestamps remove_timestamps enable_extension disable_extension
          execute add_belongs_to remove_belongs_to
        ].freeze

        ADAPTER_WHY = "raw SQL; the statement's own leading verb narrows the direction, so a literal " \
                      "`execute(\"UPDATE …\")` reads as a write and a computed string keeps the honest " \
                      "`io.db`."

        # Ambient AR calls that are neither a read nor a write of rows.
        TRANSACTIONAL = %w[transaction with_lock lock!].freeze

        module_function

        def attributions
          singleton_rows + instance_rows + relation_rows + adapter_rows + migration_rows
        end

        def singleton_rows
          rows(BASE, SINGLETON_READS, READ, singleton: true,
                                            why: "issues the SELECT at the call — this is the materializing " \
                                                 "half of the builder/materializer split") +
            rows(BASE, SINGLETON_WRITES, WRITE, singleton: true,
                                                why: "issues an INSERT / UPDATE / DELETE at the call") +
            rows(BASE, TRANSACTIONAL, TRANSACTION, singleton: true,
                                                   why: "opens a transaction; the block's own origins join " \
                                                        "by containment, so the row states only the BEGIN")
        end

        def instance_rows
          rows(BASE, INSTANCE_READS, READ,
               why: "re-reads the row (`reload`) or runs the validators, whose uniqueness checks query") +
            rows(BASE, INSTANCE_WRITES, WRITE,
                 why: "persists the record — the write a `db: none` envelope is written to catch") +
            rows(BASE, TRANSACTIONAL, TRANSACTION,
                 why: "opens a transaction / takes a row lock around the block")
        end

        def relation_rows
          rows(RELATION, RELATION_MATERIALIZERS, READ,
               why: "an Enumerable delegation on a Relation: it calls `each`, which runs the query. Not " \
                    "declared in the bundled RBS because declaring it would change how it types")
        end

        # Two rows per selector, because raw SQL is written two ways and only one of them names a type.
        # `adapter.execute(sql)` on a receiver the typer managed to name is the first; the second matches
        # `ActiveRecord::Base.connection.execute(sql)` and `User.connection.exec_query(sql)`, where the
        # connection object has no declared type but the class that handed it over is written in the source.
        def adapter_rows
          ADAPTER_SQL.flat_map do |selector|
            [
              EffectAttribution.new(
                receiver: ADAPTER, method: selector, labels: ["io.db"], narrow: "sql_verb", discharge: true,
                why: ADAPTER_WHY
              ),
              EffectAttribution.new(
                receiver: BASE, method: selector, labels: ["io.db"], narrow: "sql_verb", on_result: true,
                discharge: true,
                why: "#{ADAPTER_WHY} Matched on the result of `Model.connection`, which is how raw SQL is " \
                     "actually spelled in a Rails app."
              )
            ]
          end
        end

        def migration_rows
          rows(MIGRATION, MIGRATION_DSL, SCHEMA_WRITE,
               why: "the migration DSL issues DDL: `io.db.write` is the transport, `rails.schema.write` " \
                    "the meaning a `db/migrate/**` envelope names")
        end

        def rows(receiver, selectors, labels, why:, singleton: false)
          selectors.map do |selector|
            EffectAttribution.new(receiver: receiver, method: selector, labels: labels,
                                  singleton: singleton, discharge: true, why: why)
          end
        end

        # ADR-103 WD10 — the one edge ActiveRecord contributes: `save` runs the class body's callbacks and
        # validators. The engine owns the walk; this names the base class whose descendants it applies to.
        def edges
          [
            EffectEdge.new(
              receiver: BASE, target: :activerecord_callbacks,
              why: "`before_save :normalize` / `validate :check` / `after_commit :notify` are real, " \
                   "synchronous, in-process calls that no syntax at the call site contains"
            )
          ]
        end
      end
    end
  end
end
