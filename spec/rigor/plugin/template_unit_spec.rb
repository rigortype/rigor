# frozen_string_literal: true

require "rigor"
require "rigor/analysis/template_units"

# #392 — the value object a template-unit plugin is authored against, and the engine index built from it.
# The macro-substrate contract (`docs/internal-spec/macro-substrate.md` § Common value-object contract)
# binds it too: frozen at construction, validated at construction, value identity, `#to_h`.
RSpec.describe Rigor::Plugin::TemplateUnit do
  def unit(**overrides)
    described_class.new(
      logical_name: "users/show.html", path: "app/views/users/show.rbx",
      ruby_source: "# banner\nputs 1\n", line_map: { 2 => 1 }, self_type: "ViewContext",
      locals: { "size" => "String" }, ivar_seeds: { "@user" => "User" },
      transform_id: "identity-1", **overrides
    )
  end

  describe "the value-object contract" do
    it "is frozen and compares by value" do
      twin = unit

      expect(unit).to be_frozen
      expect(unit).to eq(twin)
      expect(unit.hash).to eq(twin.hash)
      expect(unit).not_to eq(unit(self_type: "Other"))
    end

    it "round-trips through `#to_h`" do
      expect(unit.to_h["line_map"]).to eq({ 2 => 1 })
    end

    it "survives Marshal, which is what carries it into a fork-pool worker" do
      expect(Marshal.load(Marshal.dump(unit))).to eq(unit)
    end

    it "refuses a malformed declaration at construction rather than at scan time" do
      expect { unit(logical_name: "") }.to raise_error(ArgumentError)
      expect { unit(ivar_seeds: { "user" => "User" }) }.to raise_error(ArgumentError, /ivar_seeds/)
      expect { unit(locals: { "Size" => "String" }) }.to raise_error(ArgumentError, /locals/)
      expect { unit(line_map: { 0 => 1 }) }.to raise_error(ArgumentError, /line_map/)
    end
  end

  describe "#unit_key" do
    it "is the `view:` key the effect table and the snapshot carry" do
      expect(unit.unit_key).to eq("view:users/show.html")
    end
  end

  describe "#digest" do
    it "is the source bytes, the transform id and the synthesis version, and nothing else" do
      expect(unit.digest).to eq(unit(path: "app/views/other.rbx").digest)
      expect(unit.digest).not_to eq(unit(ruby_source: "puts 2\n").digest)
      expect(unit.digest).not_to eq(unit(transform_id: "erubi-1.13").digest)
    end

    it "falls back to the declaring plugin's identity when the unit names no transform" do
      bare = unit(transform_id: nil)

      expect(bare.digest("view-demo@0.1.0")).not_to eq(bare.digest("view-demo@0.2.0"))
    end
  end

  describe "#template_line" do
    it "maps a compiled line back to the template's own" do
      expect(unit.template_line(2)).to eq(1)
    end

    # The banner on line 1 has no template line of its own. Anchoring at the nearest mapped line before it
    # — and at line 1 when there is none — keeps a diagnostic inside the file rather than past its end.
    it "anchors an unmapped line rather than reporting a line the template does not have" do
      expect(unit.template_line(1)).to eq(1)
      expect(unit.template_line(99)).to eq(1)
    end

    it "is the identity when the plugin supplied no map at all" do
      expect(unit(line_map: {}).template_line(7)).to eq(7)
    end
  end

  describe "the engine index built from it" do
    it "is empty, and costs nothing, for a registry whose plugins claim no globs" do
      registry = instance_double(Rigor::Plugin::Registry, plugins: [])

      index = Rigor::Analysis::TemplateUnits.collect(registry: registry)

      expect(index).to be_empty
      expect(index.digest).to be_nil
      expect(index.paths).to eq([])
    end
  end

  describe "suppressed_rules (#393)" do
    def unit(**overrides)
      described_class.new(logical_name: "users/show.html", path: "app/views/users/show.html.erb",
                          ruby_source: "1\n", **overrides)
    end

    it "defaults to reporting everything" do
      expect(unit.suppressed_rules).to eq([])
    end

    it "matches a family by prefix and a rule by its whole id" do
      expect(unit(suppressed_rules: ["call."]).suppressed_rules).to eq(["call."])
      expect(unit(suppressed_rules: ["call.undefined-method"]).suppressed_rules).to eq(["call.undefined-method"])
    end

    it "refuses an empty prefix, which would suppress the unit entirely" do
      expect { unit(suppressed_rules: [""]) }.to raise_error(ArgumentError, /suppressed_rules/)
    end

    it "rides the digest, so turning a family back on re-analyses" do
      expect(unit(suppressed_rules: ["call."]).digest).not_to eq(unit.digest)
    end
  end
end
