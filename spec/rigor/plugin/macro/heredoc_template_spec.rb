# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Plugin::Macro::HeredocTemplate do
  let(:has_one_attached_template) do
    described_class.new(
      receiver_constraint: "ActiveRecord::Base",
      method_name: :has_one_attached,
      symbol_arg_position: 0,
      emit: [
        { name: "\#{name}", returns: "ActiveStorage::Attached::One" },
        { name: "\#{name}_attachment", returns: "ActiveStorage::Attachment" }
      ],
      class_level_emit: [
        { name: "with_attached_\#{name}", returns: "ActiveRecord::Relation" }
      ]
    )
  end

  describe "construction" do
    it "stores the declared fields" do
      t = has_one_attached_template
      expect(t.receiver_constraint).to eq("ActiveRecord::Base")
      expect(t.method_name).to eq(:has_one_attached)
      expect(t.symbol_arg_position).to eq(0)
      expect(t.emit.size).to eq(2)
      expect(t.class_level_emit.size).to eq(1)
    end

    it "coerces emit Hash entries into Emit instances" do
      t = has_one_attached_template
      expect(t.emit).to all(be_a(described_class::Emit))
      expect(t.emit.first.name).to eq("\#{name}")
      expect(t.emit.first.returns).to eq("ActiveStorage::Attached::One")
    end

    it "accepts Emit instances directly as well as Hashes" do
      emit_instance = described_class::Emit.new(name: "\#{name}", returns: "String")
      t = described_class.new(
        receiver_constraint: "Foo",
        method_name: :bar,
        emit: [emit_instance]
      )
      expect(t.emit).to eq([emit_instance])
    end

    it "accepts String method_name and coerces to Symbol" do
      t = described_class.new(
        receiver_constraint: "Foo",
        method_name: "bar",
        emit: []
      )
      expect(t.method_name).to eq(:bar)
    end

    it "defaults symbol_arg_position to 0 and emit lists to empty arrays" do
      t = described_class.new(receiver_constraint: "Foo", method_name: :bar)
      expect(t.symbol_arg_position).to eq(0)
      expect(t.emit).to eq([])
      expect(t.class_level_emit).to eq([])
    end

    it "freezes the template and its emit lists after construction" do
      t = has_one_attached_template
      expect(t).to be_frozen
      expect(t.emit).to be_frozen
      expect(t.class_level_emit).to be_frozen
      expect(t.receiver_constraint).to be_frozen
    end

    it "is Ractor.shareable? at construction (ADR-15 Phase 1)" do
      t = has_one_attached_template
      expect(Ractor.shareable?(t)).to be(true)
    end
  end

  describe "validation" do
    it "rejects an empty receiver_constraint" do
      expect do
        described_class.new(receiver_constraint: "", method_name: :foo)
      end.to raise_error(ArgumentError, /receiver_constraint/)
    end

    it "rejects a non-Symbol-or-String method_name" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: 42)
      end.to raise_error(ArgumentError, /method_name/)
    end

    it "rejects a negative symbol_arg_position" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :bar, symbol_arg_position: -1)
      end.to raise_error(ArgumentError, /symbol_arg_position/)
    end

    it "rejects a non-Array emit argument" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :bar, emit: { name: "x", returns: "y" })
      end.to raise_error(ArgumentError, /emit must be an Array/)
    end

    it "rejects emit entries that are neither Emit nor Hash" do
      expect do
        described_class.new(receiver_constraint: "Foo", method_name: :bar, emit: ["bad"])
      end.to raise_error(ArgumentError, /Emit or Hash/)
    end

    it "rejects an Emit Hash entry missing :name" do
      expect do
        described_class.new(
          receiver_constraint: "Foo", method_name: :bar,
          emit: [{ returns: "X" }]
        )
      end.to raise_error(ArgumentError, /name must be a non-empty String/)
    end

    it "accepts an Emit Hash entry without :returns (ADR-18 — fallback to Dynamic[Top])" do
      template = described_class.new(
        receiver_constraint: "Foo", method_name: :bar,
        emit: [{ name: "y" }]
      )
      expect(template.emit.first.returns).to be_nil
      expect(template.emit.first.returns_from_arg).to be_nil
    end
  end

  describe "#to_h" do
    it "renders a stable Hash for cache-key inclusion" do
      expect(has_one_attached_template.to_h).to eq(
        "receiver_constraint" => "ActiveRecord::Base",
        "method_name" => "has_one_attached",
        "symbol_arg_position" => 0,
        "emit" => [
          { "name" => "\#{name}", "returns" => "ActiveStorage::Attached::One" },
          { "name" => "\#{name}_attachment", "returns" => "ActiveStorage::Attachment" }
        ],
        "class_level_emit" => [
          { "name" => "with_attached_\#{name}", "returns" => "ActiveRecord::Relation" }
        ]
      )
    end
  end

  describe "equality" do
    it "treats templates with equal fields as equal" do
      a = has_one_attached_template
      b = described_class.new(
        receiver_constraint: "ActiveRecord::Base",
        method_name: :has_one_attached,
        symbol_arg_position: 0,
        emit: [
          { name: "\#{name}", returns: "ActiveStorage::Attached::One" },
          { name: "\#{name}_attachment", returns: "ActiveStorage::Attachment" }
        ],
        class_level_emit: [
          { name: "with_attached_\#{name}", returns: "ActiveRecord::Relation" }
        ]
      )
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when method_name differs" do
      a = described_class.new(receiver_constraint: "Foo", method_name: :a)
      b = described_class.new(receiver_constraint: "Foo", method_name: :b)
      expect(a).not_to eq(b)
    end

    it "differs when emit differs" do
      a = described_class.new(receiver_constraint: "Foo", method_name: :a)
      b = described_class.new(
        receiver_constraint: "Foo", method_name: :a,
        emit: [{ name: "x", returns: "Y" }]
      )
      expect(a).not_to eq(b)
    end
  end

  describe described_class::Emit do
    it "freezes name and returns at construction" do
      e = described_class.new(name: "foo", returns: "Bar")
      expect(e).to be_frozen
      expect(e.name).to be_frozen
      expect(e.returns).to be_frozen
    end

    it "rejects an empty name" do
      expect { described_class.new(name: "", returns: "Bar") }.to raise_error(ArgumentError, /name/)
    end

    it "rejects an empty returns" do
      expect { described_class.new(name: "foo", returns: "") }.to raise_error(ArgumentError, /returns/)
    end

    it "accepts a nil returns (ADR-18 — falls back to Dynamic[Top] downstream)" do
      e = described_class.new(name: "foo")
      expect(e.returns).to be_nil
      expect(e.returns_from_arg).to be_nil
    end
  end

  describe described_class::ReturnsFromArg do
    it "coerces a Hash into a frozen value object" do
      r = described_class.coerce(
        position: 1,
        lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases }
      )
      expect(r).to be_a(described_class)
      expect(r).to be_frozen
      expect(r.position).to eq(1)
      expect(r.plugin_id).to eq("dry-types")
      expect(r.fact).to eq(:dry_type_aliases)
    end

    it "accepts string-keyed Hash form for cache-roundtrip parity" do
      r = described_class.coerce(
        "position" => 0,
        "lookup_via" => { "plugin_id" => "rails-routes", "fact" => "helper_table" }
      )
      expect(r.position).to eq(0)
      expect(r.plugin_id).to eq("rails-routes")
      expect(r.fact).to eq(:helper_table)
    end

    it "returns nil unchanged" do
      expect(described_class.coerce(nil)).to be_nil
    end

    it "raises on non-Hash, non-nil values" do
      expect { described_class.coerce("nope") }.to raise_error(ArgumentError, /must be a Hash/)
    end

    it "raises when lookup_via is missing" do
      expect { described_class.coerce(position: 1) }.to raise_error(ArgumentError, /lookup_via/)
    end

    it "raises on a negative position" do
      expect do
        described_class.coerce(position: -1, lookup_via: { plugin_id: "x", fact: :y })
      end.to raise_error(ArgumentError, /position/)
    end

    it "raises on an empty plugin_id" do
      expect do
        described_class.coerce(position: 0, lookup_via: { plugin_id: "", fact: :y })
      end.to raise_error(ArgumentError, /plugin_id/)
    end

    it "round-trips through to_h" do
      r = described_class.coerce(
        position: 2, lookup_via: { plugin_id: "p", fact: :f }
      )
      expect(r.to_h).to eq(
        "position" => 2,
        "lookup_via" => { "plugin_id" => "p", "fact" => "f" }
      )
    end
  end

  describe "#{described_class}::Emit with returns_from_arg" do
    it "stores the ReturnsFromArg value class on the Emit" do
      template = described_class::Emit.new(
        name: "x",
        returns_from_arg: {
          position: 1,
          lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases }
        }
      )
      expect(template.returns_from_arg).to be_a(described_class::ReturnsFromArg)
      expect(template.returns_from_arg.position).to eq(1)
    end

    it "round-trips through to_h with the returns_from_arg key" do
      template = described_class::Emit.new(
        name: "x",
        returns_from_arg: {
          position: 1,
          lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases }
        }
      )
      expect(template.to_h).to include(
        "name" => "x",
        "returns_from_arg" => a_kind_of(Hash)
      )
    end
  end
end
