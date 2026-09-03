# frozen_string_literal: true

require "spec_helper"

DRY_MONADS_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-dry-monads/lib", __dir__)
$LOAD_PATH.unshift(DRY_MONADS_PLUGIN_LIB) unless $LOAD_PATH.include?(DRY_MONADS_PLUGIN_LIB)
require "rigor-dry-monads"

RSpec.describe "plugins/rigor-dry-monads" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::DryMonads }

  describe "manifest and HKT registration" do
    it "registers dry_monads::result and dry_monads::maybe HKT tags" do
      manifest = plugin_class.manifest
      expect(manifest.id).to eq("dry-monads")
      expect(manifest.hkt_registrations.map(&:uri)).to contain_exactly(:"dry_monads::result", :"dry_monads::maybe")
      expect(manifest.hkt_definitions.map(&:uri)).to contain_exactly(:"dry_monads::result", :"dry_monads::maybe")
    end
  end

  describe "dynamic return for constructors" do
    it "infers Result from Success and allows value! call" do
      source = <<~RUBY
        def demo
          res = Success("hello")
          res.value!.upcase
        end
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "infers Maybe from Some and catches undefined method on value!" do
      source = <<~RUBY
        def demo
          m = Some(42)
          m.value!.uppercaze
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/uppercaze.*for (Integer|42)/))
    end
  end
end
