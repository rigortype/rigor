# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# ADR-130 slice 1b — the `Rigor::Plugin` interface carrier (WD1, WD4), the closed-alias memo under the erasure switch,
# and the `EXPLICIT_UNTYPED` origin, which `rigor check`'s diagnostics do not show and the parity harness therefore
# cannot (`spec/integration/interface_parity_spec.rb`).
RSpec.describe "ADR-130 Rigor::Plugin interface carrier" do
  let(:translator) { Rigor::Inference::RbsTypeTranslator }
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:sig_dir) { Dir.mktmpdir("rigor-plugin-interface") }
  let(:environment) do
    File.write(File.join(sig_dir, "probe.rbs"), <<~RBS)
      module Rigor
        module Plugin
          interface _ProbeS
            def to_str: () -> String
          end
        end
      end

      interface _Outside
        def to_str: () -> String
      end

      type probe_alias = ::Rigor::Plugin::_ProbeS | ::Integer

      class OriginProbe
        def interface_result: () -> ::Rigor::Plugin::_ProbeS
        def outside_result: () -> ::_Outside
        def nominal_result: () -> ::String
      end
    RBS
    Rigor::Environment.for_project(signature_paths: [sig_dir])
  end

  def parse(text) = RBS::Parser.parse_type(text)

  after { FileUtils.remove_entry(sig_dir) }

  describe "the carrier (WD1, WD4)" do
    it "carries a Rigor::Plugin interface as Dynamic[Interface], with its type arguments" do
      type = translator.translate(parse("::Rigor::Plugin::_Each[::Integer]"))

      expect(type).to eq(Rigor::Type::Combinator.dynamic(
                           Rigor::Type::Interface.new("Rigor::Plugin::_Each", [Rigor::Type::Combinator.nominal_of("Integer")])
                         ))
      expect(type.describe).to eq("Dynamic[Rigor::Plugin::_Each[Integer]]")
      expect(Rigor::Type::Combinator.untyped?(type)).to be(true)
    end

    it "erases every other interface, a core conversion interface and a nested namespace included" do
      %w[::_ToStr ::_Outside ::Rigor::_Scope ::Rigor::Plugin::Inner::_Scope].each do |name|
        expect(translator.translate(parse(name))).to equal(untyped), name
      end
    end

    it "erases a Rigor::Plugin interface too under the erasure switch" do
      expect(translator.with_interface_erasure { translator.translate(parse("::Rigor::Plugin::_Scope")) })
        .to equal(untyped)
    end
  end

  # WD4 — the memo is keyed by the expansion alone, so the erasure baseline must neither read nor write it.
  describe "the closed-alias memo" do
    let(:alias_type) { parse("probe_alias") }
    let(:loader) { environment.rbs_loader }

    def translate_alias = translator.translate(alias_type, alias_expander: loader)

    it "serves no default translation under the erasure switch" do
      default = translate_alias
      erased = translator.with_interface_erasure { translate_alias }

      expect(default.describe).to eq("Dynamic[Rigor::Plugin::_ProbeS] | Integer")
      expect(erased.describe).to eq("Dynamic[top] | Integer")
    end

    it "stores no erased translation for the default engine" do
      erased = translator.with_interface_erasure { translate_alias }

      expect(erased.describe).to eq("Dynamic[top] | Integer")
      expect(translate_alias.describe).to eq("Dynamic[Rigor::Plugin::_ProbeS] | Integer")
    end
  end

  # `method_dispatcher.rb`'s `EXPLICIT_UNTYPED` origin, which lens and `coverage --protection` read: a declared
  # `-> _ProbeS` result is an untyped result, as a declared `-> untyped` one is.
  describe "the EXPLICIT_UNTYPED origin" do
    def origin_for(method_name)
      node = Prism.parse("o.#{method_name}").value.statements.body.first
      scope = Rigor::Scope.empty(environment: environment)
      Rigor::Inference::MethodDispatcher.dispatch(
        receiver_type: Rigor::Type::Combinator.nominal_of("OriginProbe"), method_name: method_name,
        arg_types: [], environment: environment, call_node: node, scope: scope
      )
      scope.dynamic_origins[node]
    end

    it "records an interface-valued RBS result as explicitly untyped, as an erased one" do
      expect(origin_for(:interface_result)).to eq(Rigor::Inference::DynamicOrigin::EXPLICIT_UNTYPED)
      expect(origin_for(:outside_result)).to eq(Rigor::Inference::DynamicOrigin::EXPLICIT_UNTYPED)
      expect(origin_for(:nominal_result)).to be_nil
    end
  end
end
