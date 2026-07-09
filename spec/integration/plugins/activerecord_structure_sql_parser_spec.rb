# frozen_string_literal: true

# Focused unit coverage for the PostgreSQL `db/structure.sql` parser (the `schema_format = :sql` schema
# source). The full-pipeline behaviour is exercised in `activerecord_plugin_spec.rb`; this locks the
# DDL-specific column shape (type mapping, array flag, multi-word types, constraint / partition skipping).

require "spec_helper"

ar_plugin_lib = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(ar_plugin_lib) unless $LOAD_PATH.include?(ar_plugin_lib)
require "rigor-activerecord"

RSpec.describe "plugins/rigor-activerecord StructureSqlParser" do
  def parse(sql) = Rigor::Plugin::Activerecord::StructureSqlParser.parse(sql)

  it "maps common PostgreSQL types to the same Ruby types as the schema.rb parser" do
    table = parse(<<~SQL)
      CREATE TABLE widgets (
          id bigint NOT NULL,
          count integer,
          size smallint,
          name character varying NOT NULL,
          body text,
          active boolean DEFAULT false,
          price numeric(10,2),
          ratio double precision,
          created_at timestamp without time zone,
          published_on date,
          payload jsonb,
          token uuid
      );
    SQL
    cols = table.columns_for("widgets").to_h { |c| [c.name, c.ruby_type] }
    expect(cols).to eq(
      "id" => "Integer", "count" => "Integer", "size" => "Integer",
      "name" => "String", "body" => "String", "active" => "bool",
      "price" => "Float", "ratio" => "Float", "created_at" => "Time",
      "published_on" => "Date", "payload" => "Object", "token" => "String"
    )
  end

  it "flags Postgres array columns and keeps the element type" do
    table = parse("CREATE TABLE t (\n  tag_ids bigint[],\n  labels character varying[]\n);\n")
    tag_ids = table.column("t", "tag_ids")
    expect(tag_ids.array?).to be(true)
    expect(tag_ids.ruby_type).to eq("Integer")
    expect(table.column("t", "labels").array?).to be(true)
  end

  it "skips table-level constraint lines" do
    table = parse(<<~SQL)
      CREATE TABLE t (
          id bigint NOT NULL,
          email character varying,
          CONSTRAINT check_email CHECK ((email IS NOT NULL)),
          PRIMARY KEY (id)
      );
    SQL
    expect(table.columns_for("t").map(&:name)).to contain_exactly("id", "email")
  end

  it "handles a multi-line quoted default without inventing a continuation column" do
    table = parse(<<~SQL)
      CREATE TABLE t (
          scopes character varying DEFAULT '--- []
      '::character varying NOT NULL,
          active boolean
      );
    SQL
    expect(table.columns_for("t").map(&:name)).to contain_exactly("scopes", "active")
    expect(table.column("t", "scopes").ruby_type).to eq("String")
  end

  it "keeps unqualified / public tables and drops other-schema partitions" do
    table = parse(<<~SQL)
      CREATE TABLE users (
          id bigint NOT NULL
      );
      CREATE TABLE public.accounts (
          id bigint NOT NULL
      );
      CREATE TABLE gitlab_partitions_dynamic.users_part (
          id bigint NOT NULL
      );
    SQL
    expect(table.table_names).to contain_exactly("users", "accounts")
  end

  it "degrades an unknown column type to Object rather than dropping the column" do
    table = parse("CREATE TABLE t (\n  vec tsvector,\n  span int8range\n);\n")
    expect(table.columns_for("t").map(&:name)).to contain_exactly("vec", "span")
    expect(table.column("t", "vec").ruby_type).to eq("Object")
  end
end
