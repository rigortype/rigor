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

    it "registers the named column with the type of an id: symbol"
    it "registers the named column as an integer when there is no id: option"
    it "reads a Symbol primary key name"
    it "keeps the id column"
    it "adds nothing for a composite primary key, whose columns the block declares"
    it "adds nothing when id: false says the table has no primary key column"
    it "lets a column the block declares win over the option"
  end
end
