# frozen_string_literal: true

require_relative "schema_table"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Parses a PostgreSQL `db/structure.sql` (the `schema_format = :sql` schema dump) into the same
      # {SchemaTable} the Ruby-DSL {SchemaParser} produces, so a project that commits `structure.sql`
      # instead of `schema.rb` is no longer inert (GitLab-class apps use `structure.sql`; without this the
      # plugin skips every AR call check and — worse — degrades ordinary relation chains to `Array`,
      # cascading false diagnostics).
      #
      # The dump is regular enough to read line-by-line without a SQL parser. `pg_dump` emits, per table:
      #
      #   CREATE TABLE namespaces (
      #       id bigint NOT NULL,
      #       name character varying NOT NULL,
      #       visibility_level integer DEFAULT 20 NOT NULL,
      #       tag_ids bigint[],
      #       created_at timestamp without time zone
      #   );
      #
      # Load-bearing regularities this relies on: column names / types are lowercase, column modifiers
      # (`NOT NULL`, `DEFAULT …`, `GENERATED …`, `COLLATE …`) are UPPERCASE, one column per line, the body
      # closes on a line starting with `)`. So the type is the run of tokens before the first
      # uppercase-initial token, and a table-level constraint line (`CONSTRAINT …`, `PRIMARY KEY …`) is
      # recognised by its uppercase leading keyword and skipped. Anything it cannot map (custom enum,
      # `tsvector`, `ltree`) degrades to `Object` via {SchemaTable.ruby_type_for} — never a dropped column,
      # which would turn every query on it into a false `unknown-column`.
      class StructureSqlParser
        # Normalised PostgreSQL type (lowercased, length/precision + `[]` stripped) → the Rails column-type
        # symbol {SchemaTable.ruby_type_for} already understands. Unmapped types fall through to their own
        # symbol, which `ruby_type_for` maps to `Object` (the safe "do not narrow" default).
        PG_TYPE_TO_RAILS = {
          "bigint" => :bigint, "int8" => :bigint, "bigserial" => :bigint,
          "integer" => :integer, "int" => :integer, "int4" => :integer, "serial" => :integer,
          "smallint" => :integer, "int2" => :integer, "smallserial" => :integer,
          "boolean" => :boolean, "bool" => :boolean,
          "text" => :text,
          "character varying" => :string, "varchar" => :string,
          "character" => :string, "char" => :string, "name" => :string, "citext" => :citext,
          "timestamp without time zone" => :datetime, "timestamp with time zone" => :datetime,
          "timestamp" => :datetime, "timestamptz" => :datetime,
          "date" => :date,
          "time without time zone" => :time, "time with time zone" => :time, "time" => :time,
          "numeric" => :decimal, "decimal" => :decimal, "money" => :decimal,
          "double precision" => :float, "real" => :float, "float8" => :float, "float4" => :float,
          "bytea" => :binary,
          "json" => :json, "jsonb" => :jsonb,
          "uuid" => :uuid, "inet" => :inet, "cidr" => :string, "macaddr" => :string
        }.freeze

        # Uppercase leading keywords that mark a table-level constraint line rather than a column.
        CONSTRAINT_KEYWORDS = %w[CONSTRAINT PRIMARY UNIQUE CHECK FOREIGN EXCLUDE LIKE PARTITION].freeze

        # @param source [String] contents of `db/structure.sql`
        # @return [SchemaTable]
        def self.parse(source)
          new.parse(source)
        end

        def parse(source)
          tables = {}
          each_create_table(source.to_s) do |table_name, body_lines|
            columns = parse_columns(body_lines)
            tables[table_name] = columns unless columns.empty?
          end
          SchemaTable.new(tables.freeze)
        end

        private

        # Yields `[table_name, body_lines]` for every `CREATE TABLE … (` … `)` block. Body lines are the raw
        # lines between the opening `(` line and the closing `)` line.
        def each_create_table(source)
          lines = source.lines
          index = 0
          while index < lines.length
            match = lines[index].match(/\ACREATE (?:UNLOGGED |TEMPORARY )?TABLE (?:IF NOT EXISTS )?(\S+)\s*\(/)
            unless match
              index += 1
              next
            end

            table_name = normalize_table_name(match[1])
            index += 1
            body = []
            while index < lines.length && lines[index] !~ /\A\s*\)/
              body << lines[index]
              index += 1
            end
            yield(table_name, body) if table_name
            index += 1 # step past the closing `)` line
          end
        end

        # Strips quotes and a leading schema qualifier. Only the default `public` schema (or an unqualified
        # name) is accepted; other schemas (`gitlab_partitions_dynamic.*`, etc.) are partitions of a base
        # table already emitted unqualified, so returning nil skips them without losing a real table.
        def normalize_table_name(raw)
          name = raw.delete('"')
          if name.include?(".")
            schema, table = name.split(".", 2)
            return nil unless schema == "public"

            name = table
          end
          name.empty? ? nil : name
        end

        def parse_columns(body_lines)
          columns = {}
          # A column's `DEFAULT` may carry a multi-line single-quoted string (a serialized YAML default,
          # `DEFAULT '--- []\n'::character varying`). The column name + type sit before the `DEFAULT`, so
          # the first physical line still parses correctly; the continuation lines must be skipped or they
          # read as bogus columns (`'::character varying`). A line with an ODD count of single quotes opens
          # (or closes) such a string — PG doubles a literal quote (`''`), so escapes stay even and only a
          # genuinely unterminated string toggles the state.
          in_string = false
          body_lines.each do |raw|
            if in_string
              in_string = false if raw.count("'").odd?
              next
            end
            in_string = true if raw.count("'").odd?

            line = raw.strip.chomp(",")
            next if line.empty?

            name, rest = line.split(/\s+/, 2)
            next if name.nil? || rest.nil?
            next if CONSTRAINT_KEYWORDS.include?(name) # a table-level constraint, not a column

            column = build_column(name.delete('"'), rest)
            columns[column.name] = column if column
          end
          columns.freeze
        end

        def build_column(name, rest)
          type_str, array = extract_type(rest)
          return nil if type_str.empty?

          rails_type = PG_TYPE_TO_RAILS.fetch(type_str, type_str.to_sym)
          SchemaTable::Column.new(
            name: name,
            type: rails_type,
            ruby_type: SchemaTable.ruby_type_for(rails_type),
            array: array
          )
        end

        # The type is every token before the first uppercase-initial token (a column modifier such as
        # `NOT`, `NULL`, `DEFAULT`, `GENERATED`, `COLLATE`). A trailing `[]` marks a Postgres array column;
        # a `(length[,scale])` specifier is dropped. Returns `[normalized_type, array?]`.
        def extract_type(rest)
          type_tokens = []
          rest.split(/\s+/).each do |token|
            break if token.match?(/\A[A-Z]/)

            type_tokens << token
          end
          type_str = type_tokens.join(" ")
          array = type_str.include?("[]")
          type_str = type_str.gsub("[]", "").gsub(/\([0-9,\s]*\)/, "").strip.downcase
          [type_str, array]
        end
      end
    end
  end
end
