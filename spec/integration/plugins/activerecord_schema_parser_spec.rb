# frozen_string_literal: true

# Focused unit coverage for how the `db/schema.rb` parser reads the primary key of a `create_table` call. The
# full-pipeline behaviour is exercised in `activerecord_plugin_spec.rb`.

require "spec_helper"

ar_plugin_lib = File.expand_path("../../../plugins/rigor-activerecord/lib", __dir__)
$LOAD_PATH.unshift(ar_plugin_lib) unless $LOAD_PATH.include?(ar_plugin_lib)
require "rigor-activerecord"

RSpec.describe "plugins/rigor-activerecord SchemaParser" do
  def parse(source) = Rigor::Plugin::Activerecord::SchemaParser.parse(source)

  describe "the primary_key: option of create_table" do
    it "registers the named column with the type of an id: hash" do
      table = parse(<<~RUBY)
        create_table "settings", primary_key: "name", id: { type: :string, limit: 64 }, force: :cascade do |t|
          t.text "value"
        end
      RUBY
      expect(table.column("settings", "name").ruby_type).to eq("String")
    end

    it "registers the named column with the type of an id: symbol" do
      table = parse(%(create_table "items", primary_key: "code", id: :string do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("String")
    end

    it "registers the named column as an integer when there is no id: option" do
      table = parse(%(create_table "items", primary_key: "num" do |t|\nend\n))
      expect(table.column("items", "num").ruby_type).to eq("Integer")
    end

    it "reads a Symbol primary key name" do
      table = parse(%(create_table :items, primary_key: :code, id: :string do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("String")
    end

    it "keeps the id column" do
      table = parse(%(create_table "items", primary_key: "code", id: :string do |t|\nend\n))
      expect(table.column("items", "id")).not_to be_nil
    end

    it "reads the dumped spelling of a uuid key with a default" do
      table = parse(%(create_table "items", primary_key: "code", id: :uuid, default: -> { "gen()" } do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("String")
    end

    it "reads the dumped spelling of an integer key without a default" do
      table = parse(%(create_table "items", primary_key: "num", id: :integer, default: nil do |t|\nend\n))
      expect(table.column("items", "num").ruby_type).to eq("Integer")
    end

    it "registers an integer key when the id: hash names no type" do
      table = parse(%(create_table "items", primary_key: "num", id: { comment: "x" } do |t|\nend\n))
      expect(table.column("items", "num").ruby_type).to eq("Integer")
    end

    it "flags an array key and keeps its element type" do
      table = parse(%(create_table "items", primary_key: "tags", id: { type: :string, array: true } do |t|\nend\n))
      column = table.column("items", "tags")
      expect([column.array?, column.ruby_type]).to eq([true, "String"])
    end

    it "reads array: false as a scalar key" do
      table = parse(%(create_table "items", primary_key: "code", id: { type: :string, array: false } do |t|\nend\n))
      column = table.column("items", "code")
      expect([column.array?, column.ruby_type]).to eq([false, "String"])
    end

    it "leaves a decimal key untyped, because its Ruby class depends on the scale" do
      table = parse(%(create_table "items", primary_key: "num", id: { type: :decimal, scale: 0 } do |t|\nend\n))
      expect(table.column("items", "num").ruby_type).to eq("Object")
    end

    it "leaves the key untyped when id: is not a literal" do
      table = parse(%(create_table "items", primary_key: "code", id: MY_TYPE do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("Object")
    end

    it "leaves the key untyped when the type in the id: hash is not a literal" do
      table = parse(%(create_table "items", primary_key: "code", id: { type: MY_TYPE } do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("Object")
    end

    it "leaves the key untyped when the id: hash has a splat" do
      table = parse(%(create_table "items", primary_key: "code", id: { **ID_OPTIONS } do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("Object")
    end

    it "leaves the key untyped when the call has a splat that may hold id:" do
      table = parse(%(create_table "items", primary_key: "code", **TABLE_OPTIONS do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("Object")
    end

    it "leaves the key untyped when array: is not a literal" do
      table = parse(%(create_table "items", primary_key: "tags", id: { type: :string, array: FLAG } do |t|\nend\n))
      expect(table.column("items", "tags").ruby_type).to eq("Object")
    end

    it "adds nothing when id: nil creates no primary key column" do
      table = parse(%(create_table "items", primary_key: "code", id: nil do |t|\n  t.text "value"\nend\n))
      expect(table.columns_for("items").map(&:name)).to eq(["value"])
    end

    it "keeps an as: table's key queryable but untyped, because the query may define it" do
      table = parse(%(create_table "items", primary_key: "code", as: "SELECT 1 AS code"\n))
      expect(table.column("items", "code").ruby_type).to eq("Object")
    end

    it "keeps the key queryable but untyped when as: is nil" do
      table = parse(%(create_table "items", primary_key: "code", as: nil, id: :string do |t|\nend\n))
      expect(table.column("items", "code").ruby_type).to eq("Object")
    end

    {
      "a non-literal key in the id: hash" => "id: { KEY => :string }",
      "an interpolated key in the id: hash" => %(id: { "\#{KEY}": :string }),
      "a repeated key in the id: hash" => "id: { type: :integer, type: :string }",
      "a non-literal key in the call" => "KEY => { type: :string }",
      "an interpolated key in the call" => %("\#{KEY}": :string),
      "a repeated id: in the call" => "id: :integer, id: :string",
      "as: false" => "id: :string, as: false",
      "a non-literal as:" => "id: :string, as: QUERY",
      "a splat after id: false" => "id: false, **TABLE_OPTIONS",
      "a splat after id: nil" => "id: nil, **TABLE_OPTIONS"
    }.each do |description, options|
      it "leaves the key untyped with #{description}" do
        table = parse(%(create_table "items", primary_key: "code", #{options} do |t|\nend\n))
        expect(table.column("items", "code").ruby_type).to eq("Object")
      end
    end

    {
      "a splat may override id: false" => "id: false, **TABLE_OPTIONS",
      "a splat may override id: nil" => "id: nil, **TABLE_OPTIONS",
      "a splat may hold id:" => "**TABLE_OPTIONS",
      "a repeated id: key ends in false" => "id: :string, id: false"
    }.each do |description, options|
      it "keeps the id column untyped when #{description}" do
        table = parse(%(create_table "items", #{options} do |t|\nend\n))
        expect(table.column("items", "id").ruby_type).to eq("Object")
      end
    end

    it "types the id column as an integer when the call is read completely" do
      table = parse(%(create_table "items", force: :cascade do |t|\nend\n))
      expect(table.column("items", "id").ruby_type).to eq("Integer")
    end

    it "adds nothing for a composite primary key, whose columns the block declares" do
      table = parse(<<~RUBY)
        create_table "pairs", primary_key: ["x", "y"], force: :cascade do |t|
          t.integer "x"
          t.integer "y"
        end
      RUBY
      expect(table.columns_for("pairs").map(&:name)).to contain_exactly("id", "x", "y")
    end

    it "adds nothing when id: false says the table has no primary key column" do
      table = parse(<<~RUBY)
        create_table "items", primary_key: "code", id: false do |t|
          t.text "value"
        end
      RUBY
      expect(table.columns_for("items").map(&:name)).to eq(["value"])
    end

    it "lets a column the block declares win over the option" do
      table = parse(<<~RUBY)
        create_table "items", primary_key: "code", id: :integer do |t|
          t.string "code"
        end
      RUBY
      expect(table.column("items", "code").ruby_type).to eq("String")
    end
  end

  describe "the id reader's type" do
    it "takes the type of the named primary key" do
      table = parse(<<~RUBY)
        create_table "settings", primary_key: "name", id: { type: :string, limit: 64 }, force: :cascade do |t|
          t.text "value"
        end
      RUBY
      expect(table.column("settings", "id").ruby_type).to eq("String")
    end

    it "stays an integer when primary_key: names a key with no id: type" do
      table = parse(%(create_table "items", primary_key: "num" do |t|\nend\n))
      expect(table.column("items", "id").ruby_type).to eq("Integer")
    end

    it "stays an integer when primary_key: names an integer key" do
      table = parse(%(create_table "items", primary_key: "num", id: :bigint do |t|\nend\n))
      expect(table.column("items", "id").ruby_type).to eq("Integer")
    end

    it "reads the id: type of each table with no primary_key: option" do
      table = parse(<<~RUBY)
        ActiveRecord::Schema[8.1].define(version: 1) do
          create_table "tokens", id: :uuid do |t|
            t.text "value"
          end

          create_table "codes", id: :string do |t|
            t.text "value"
          end

          create_table "slugs", id: { type: :string, limit: 64 } do |t|
            t.text "value"
          end

          create_table "bigs", id: :bigint do |t|
            t.text "value"
          end
        end
      RUBY
      expect(table.column("tokens", "id").ruby_type).to eq("String")
      expect(table.column("codes", "id").ruby_type).to eq("String")
      expect(table.column("slugs", "id").ruby_type).to eq("String")
      expect(table.column("bigs", "id").ruby_type).to eq("Integer")
    end

    it "reads id: true as the default integer key" do
      table = parse(%(create_table "items", id: true do |t|\nend\n))
      expect(table.column("items", "id").ruby_type).to eq("Integer")
    end

    {
      "a composite primary_key:" => %(primary_key: ["x", "y"], force: :cascade),
      "a non-literal primary_key:" => "primary_key: KEY",
      "a decimal id: type" => "id: { type: :decimal }",
      "a non-literal id:" => "id: MY_TYPE",
      "a non-literal type in the id: hash" => "id: { type: MY_TYPE }",
      "a splat in the id: hash" => "id: { **ID_OPTIONS }",
      "a splat that may hold id:" => "**TABLE_OPTIONS",
      "an as: table" => %(as: "SELECT 1 AS id", id: :string)
    }.each do |description, options|
      it "leaves id untyped with #{description}" do
        table = parse(%(create_table "items", #{options} do |t|\nend\n))
        expect(table.column("items", "id").ruby_type).to eq("Object")
      end
    end
  end

  describe "a decimal column's class follows its scale" do
    it "reads a decimal at scale 0 as an Integer, as DecimalWithoutScale does" do
      table = parse(<<~RUBY)
        create_table "prices" do |t|
          t.decimal "whole", precision: 20, scale: 0
        end
      RUBY
      expect(table.column("prices", "whole").ruby_type).to eq("Integer")
    end

    it "reads a decimal at a negative scale as a BigDecimal, not a Float" do
      table = parse(<<~RUBY)
        create_table "prices" do |t|
          t.decimal "rounded", precision: 10, scale: -2
        end
      RUBY
      expect(table.column("prices", "rounded").ruby_type).to eq("BigDecimal")
    end

    it "reads a decimal at a non-zero scale as a BigDecimal, not a Float" do
      table = parse(<<~RUBY)
        create_table "prices" do |t|
          t.decimal "fractional", precision: 10, scale: 2
        end
      RUBY
      expect(table.column("prices", "fractional").ruby_type).to eq("BigDecimal")
    end

    it "leaves a decimal with no scale untyped, because the adapter decides it" do
      table = parse(<<~RUBY)
        create_table "prices" do |t|
          t.decimal "amount", precision: 10
        end
      RUBY
      expect(table.column("prices", "amount").ruby_type).to eq("Object")
    end

    it "leaves a decimal with a non-literal scale untyped" do
      table = parse(<<~RUBY)
        create_table "prices" do |t|
          t.decimal "amount", precision: 10, scale: SCALE
        end
      RUBY
      expect(table.column("prices", "amount").ruby_type).to eq("Object")
    end

    it "reads the scale of a generic t.column decimal the same way" do
      table = parse(<<~RUBY)
        create_table "prices" do |t|
          t.column "whole", :decimal, precision: 20, scale: 0
          t.column "fractional", :decimal, precision: 10, scale: 2
        end
      RUBY
      expect(table.column("prices", "whole").ruby_type).to eq("Integer")
      expect(table.column("prices", "fractional").ruby_type).to eq("BigDecimal")
    end

    it "leaves a decimal untyped when a splat may carry the scale" do
      table = parse(%(create_table "prices" do |t|\n  t.decimal "amount", scale: 0, **OPTIONS\nend\n))
      expect(table.column("prices", "amount").ruby_type).to eq("Object")
    end
  end
end
