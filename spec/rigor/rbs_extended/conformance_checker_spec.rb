# frozen_string_literal: true

require "rigor/rbs_extended"
require "rigor/rbs_extended/conformance_checker"
require "tmpdir"

RSpec.describe Rigor::RbsExtended::ConformanceChecker do
  let(:stub_loader) do
    loader = instance_double(Rigor::Environment::RbsLoader)
    allow(loader).to receive(:each_class_decl_annotation_with_name)
    loader
  end

  describe ".scan" do
    it "returns an empty array when the loader is nil" do
      expect(described_class.scan(nil)).to eq([])
    end

    it "returns an empty array when no annotations are present" do
      expect(described_class.scan(stub_loader)).to eq([])
    end
  end

  # Builds a real `Rigor::Environment::RbsLoader` over a tmpdir containing
  # `rbs`, mirroring the fixture pattern in
  # `spec/rigor/environment/rbs_loader_spec.rb` (`signature_paths:` +
  # `Dir.mktmpdir` + `File.write`). Exercises `.scan` end-to-end (real
  # `each_class_decl_annotation_with_name` / `instance_definition` /
  # `interface_definition`), rather than stubbing the loader, so it drives
  # `check_one` and the signature-mismatch detail generators for real.
  def scan_rbs(rbs)
    Dir.mktmpdir("rigor-conformance-checker-spec-") do |tmpdir|
      File.write(File.join(tmpdir, "fixture.rbs"), rbs)
      loader = Rigor::Environment::RbsLoader.new(signature_paths: [tmpdir])
      return described_class.scan(loader)
    end
  end

  describe ".scan end-to-end over real RBS fixtures" do
    it "returns [] when the annotated class provides every required method" do
      records = scan_rbs(<<~RBS)
        interface _RewindDemo
          def rewind: () -> void
          def read: () -> String
        end

        %a{rigor:v1:conforms-to _RewindDemo}
        class FullyConforms
          def rewind: () -> void
          def read: () -> String
        end
      RBS

      expect(records).to eq([])
    end

    it "emits Unsatisfied with exactly the missing methods when the class lacks a required method" do
      records = scan_rbs(<<~RBS)
        interface _RewindDemo
          def rewind: () -> void
          def read: () -> String
        end

        %a{rigor:v1:conforms-to _RewindDemo}
        class MissingRewind
          def read: () -> String
        end
      RBS

      expect(records.size).to eq(1)
      record = records.first
      expect(record).to be_a(described_class::Unsatisfied)
      expect(record.class_name).to eq("MissingRewind")
      expect(record.interface_name).to eq("_RewindDemo")
      expect(record.missing_methods).to contain_exactly(:rewind)
      expect(record.location).not_to be_nil
    end

    it "lists every missing method (contain_exactly, order-independent) when several are absent" do
      records = scan_rbs(<<~RBS)
        interface _Wide
          def alpha: () -> void
          def beta: () -> void
          def gamma: () -> void
        end

        %a{rigor:v1:conforms-to _Wide}
        class MissingSeveral
          def gamma: () -> void
        end
      RBS

      unsatisfied = records.find { |r| r.is_a?(described_class::Unsatisfied) }
      expect(unsatisfied.missing_methods).to contain_exactly(:alpha, :beta)
    end

    it "emits UnresolvedInterface when the named interface is not loaded" do
      records = scan_rbs(<<~RBS)
        %a{rigor:v1:conforms-to _NoSuchInterface}
        class BadInterfaceRef
        end
      RBS

      expect(records.size).to eq(1)
      record = records.first
      expect(record).to be_a(described_class::UnresolvedInterface)
      expect(record.class_name).to eq("BadInterfaceRef")
      expect(record.interface_name).to eq("_NoSuchInterface")
      expect(record.location).not_to be_nil
    end

    it "resolves an interface name relative to the declaring class's namespace" do
      records = scan_rbs(<<~RBS)
        module Buffers
          interface _Stream
            def read: () -> String
          end

          %a{rigor:v1:conforms-to _Stream}
          class MyBuffer
          end
        end
      RBS

      # Only `Buffers::_Stream` exists (no top-level `_Stream`); resolution
      # must walk the class's own namespace prefixes to find it, rather
      # than falling through to UnresolvedInterface.
      expect(records.none?(described_class::UnresolvedInterface)).to be(true)
      unsatisfied = records.find { |r| r.is_a?(described_class::Unsatisfied) }
      expect(unsatisfied).not_to be_nil
      expect(unsatisfied.class_name).to eq("Buffers::MyBuffer")
      expect(unsatisfied.interface_name).to eq("_Stream")
      expect(unsatisfied.missing_methods).to contain_exactly(:read)
    end

    describe "signature compatibility — return type (return_detail)" do
      it "flags a provided return type that is not a subtype of the required return type" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: () -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class WidensReturn
            def read: () -> (String | Integer)
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.class_name).to eq("WidensReturn")
        expect(incompatible.interface_name).to eq("_ReaderDemo")
        expect(incompatible.method_name).to eq(:read)
        # Load-bearing substrings a consumer depends on: both type names
        # and the "not a subtype" relation — not the exact prose framing.
        expect(incompatible.detail).to include("return type")
        expect(incompatible.detail).to match(/String.*Integer|Integer.*String/)
        expect(incompatible.detail).to include("not a subtype")
        expect(incompatible.detail).to include("String")
      end

      it "stays silent when the provided return type is a covariant subtype" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: () -> Numeric
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class NarrowsReturnCovariantly
            def read: () -> Integer
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end
    end

    describe "signature compatibility — parameters (param_detail)" do
      it "flags a provided parameter type that does not accept the required (wider) parameter type" do
        records = scan_rbs(<<~RBS)
          interface _WriterDemo
            def write: (Object value) -> void
          end

          %a{rigor:v1:conforms-to _WriterDemo}
          class NarrowsParam
            def write: (String value) -> void
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.method_name).to eq(:write)
        expect(incompatible.detail).to include("parameter 1")
        expect(incompatible.detail).to include("does not accept")
        expect(incompatible.detail).to include("String")
        expect(incompatible.detail).to include("Object")
      end

      it "reports the correct 1-based parameter index for a mismatch past the first parameter" do
        records = scan_rbs(<<~RBS)
          interface _WriterDemo
            def write: (String tag, Object value) -> void
          end

          %a{rigor:v1:conforms-to _WriterDemo}
          class NarrowsSecondParam
            def write: (String tag, String value) -> void
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.detail).to include("parameter 2")
        expect(incompatible.detail).not_to include("parameter 1")
      end

      it "stays silent when the provided parameter type is contravariant (widened)" do
        records = scan_rbs(<<~RBS)
          interface _WriterDemo
            def write: (Integer value) -> void
          end

          %a{rigor:v1:conforms-to _WriterDemo}
          class WidensParamContravariantly
            def write: (Numeric value) -> void
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end
    end

    describe "arity divergence (arity_detail)" do
      it "flags a provided method that requires more positionals than the interface allows" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (String s) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class RequiresMorePositionals
            def read: (String s, Integer n) -> String
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.detail).to include("requires 2 positional argument")
        expect(incompatible.detail).to include("allows at most 1")
      end

      it "flags a provided method that accepts fewer positionals than the interface requires" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (String s, Integer n) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class AcceptsFewerPositionals
            def read: (String s) -> String
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.detail).to include("accepts at most 1")
        expect(incompatible.detail).to include("requires at least 2")
      end

      it "pluralizes singular counts correctly (1 positional argument, not arguments)" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: () -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class RequiresOneExtra
            def read: (String s) -> String
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.detail).to include("requires 1 positional argument ")
        expect(incompatible.detail).not_to include("requires 1 positional arguments")
      end

      it "stays silent when the provided method has a rest parameter covering extra required positionals" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (String s, Integer n) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class RestCoversExtra
            def read: (String s, *untyped rest) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end

      it "stays silent when the interface itself has a rest parameter (unbounded arity range)" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (String s, *untyped rest) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class InterfaceHasRest
            def read: (String s, Integer n) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end

      it "stays silent when arity matches exactly (no divergence at the boundary)" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (String s, ?Integer n) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class ExactArityMatch
            def read: (String s, ?Integer n) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end
    end

    describe "keyword-requiredness divergence (keyword_detail)" do
      it "flags a provided method missing a keyword the interface requires" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (encoding: String) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class MissingRequiredKeyword
            def read: () -> String
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.detail).to include("does not accept required keyword")
        expect(incompatible.detail).to include("`encoding:`")
      end

      it "flags a provided method that requires a keyword the interface does not declare" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: () -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class ExtraRequiredKeyword
            def read: (encoding: String) -> String
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.detail).to include("requires keyword")
        expect(incompatible.detail).to include("`encoding:`")
        expect(incompatible.detail).to include("not declared by the interface")
      end

      it "pluralizes the keyword noun when several keywords are listed" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (a: String, b: String) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class MissingTwoKeywords
            def read: () -> String
          end
        RBS

        incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
        expect(incompatible).not_to be_nil
        expect(incompatible.detail).to include("does not accept required keywords")
        expect(incompatible.detail).to include("`a:`")
        expect(incompatible.detail).to include("`b:`")
      end

      it "stays silent when the provided method accepts the required keyword as optional" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (encoding: String) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class AcceptsAsOptional
            def read: (?encoding: String) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end

      it "stays silent when the provided method has a keyword rest (**kwargs)" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (encoding: String) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class HasKeywordRest
            def read: (**untyped opts) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end

      it "stays silent when the interface has a keyword rest (**kwargs)" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (**untyped opts) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class ProvidedRequiresKeyword
            def read: (encoding: String) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end
    end

    describe "Dynamic[Top] and multi-overload skip guards" do
      it "does not fire return_detail/param_detail when the required side type is untyped (Dynamic[Top])" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (untyped value) -> untyped
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class DynamicRequiredSide
            def read: (String value) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end

      it "does not fire return_detail/param_detail when the provided side type is untyped (Dynamic[Top])" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (String value) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class DynamicProvidedSide
            def read: (untyped value) -> untyped
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end

      it "does not fire any signature_mismatch check when the interface method is overloaded" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (String s) -> String
                     | (Integer i) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class ProvidedMatchesNeither
            def read: (Object o) -> String
          end
        RBS

        # signature_mismatch short-circuits to nil for a multi-method-type
        # required signature, before any of the detail generators run —
        # even though the single provided overload would otherwise
        # contravariantly-fail against either required overload.
        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end

      it "does not fire any signature_mismatch check when the provided method is overloaded" do
        records = scan_rbs(<<~RBS)
          interface _ReaderDemo
            def read: (Object o) -> String
          end

          %a{rigor:v1:conforms-to _ReaderDemo}
          class ProvidedIsOverloaded
            def read: (String s) -> String
                     | (Integer i) -> String
          end
        RBS

        expect(records.none?(described_class::IncompatibleSignature)).to be(true)
      end
    end

    it "checks missing-method presence and signature compatibility independently per interface method" do
      # collect_missing and collect_incompatible both run over the same
      # (required, provided) pair; a class can simultaneously be missing
      # one required method and provide an incompatible second one.
      records = scan_rbs(<<~RBS)
        interface _Combo
          def rewind: () -> void
          def read: () -> String
        end

        %a{rigor:v1:conforms-to _Combo}
        class MissingOneWrongOther
          def read: () -> (String | Integer)
        end
      RBS

      unsatisfied = records.find { |r| r.is_a?(described_class::Unsatisfied) }
      incompatible = records.find { |r| r.is_a?(described_class::IncompatibleSignature) }
      expect(unsatisfied.missing_methods).to contain_exactly(:rewind)
      expect(incompatible.method_name).to eq(:read)
    end

    it "combines multiple conforms-to directives on the same class as independent checks" do
      records = scan_rbs(<<~RBS)
        interface _First
          def a: () -> void
        end

        interface _Second
          def b: () -> void
        end

        %a{rigor:v1:conforms-to _First}
        %a{rigor:v1:conforms-to _Second}
        class MultiConform
        end
      RBS

      unsatisfied = records.grep(described_class::Unsatisfied)
      expect(unsatisfied.size).to eq(2)
      expect(unsatisfied.map(&:interface_name)).to contain_exactly("_First", "_Second")
      expect(unsatisfied.map(&:missing_methods)).to contain_exactly([:a], [:b])
    end
  end

  describe "private helpers" do
    describe "namespace_prefixes" do
      it "splits qualified names into longest-first prefixes" do
        expect(described_class.send(:namespace_prefixes, "Foo::Bar::Baz")).to eq(
          ["Foo::Bar::Baz", "Foo::Bar", "Foo"]
        )
      end

      it "returns [name] for a top-level name" do
        expect(described_class.send(:namespace_prefixes, "String")).to eq(["String"])
      end
    end

    describe "candidate_interface_names" do
      it "builds namespace-qualified candidates longest-prefix-first, then the bare name last" do
        expect(described_class.send(:candidate_interface_names, "Foo::Bar", "_Iface")).to eq(
          ["Foo::Bar::_Iface", "Foo::_Iface", "_Iface"]
        )
      end
    end

    describe "normalize" do
      it "strips leading ::" do
        expect(described_class.send(:normalize, "::String")).to eq("String")
      end

      it "leaves a bare name unchanged" do
        expect(described_class.send(:normalize, "String")).to eq("String")
      end
    end

    describe "dynamic_top?" do
      it "returns true for untyped (Dynamic)" do
        dyn = Rigor::Type::Combinator.untyped
        expect(described_class.send(:dynamic_top?, dyn)).to be(true)
      end

      it "returns false for Nominal types" do
        nom = Rigor::Type::Combinator.nominal_of("String")
        expect(described_class.send(:dynamic_top?, nom)).to be(false)
      end
    end

    describe "keyword_mismatch_message" do
      it "uses the singular noun and no trailing suffix by default" do
        message = described_class.send(:keyword_mismatch_message, "does not accept required", [:encoding])
        expect(message).to eq("does not accept required keyword `encoding:`")
      end

      it "uses the plural noun and sorts multiple keys" do
        message = described_class.send(:keyword_mismatch_message, "requires", %i[zeta alpha])
        expect(message).to eq("requires keywords `alpha:`, `zeta:`")
      end

      it "appends the given suffix" do
        message = described_class.send(
          :keyword_mismatch_message, "requires", [:encoding], suffix: " not declared by the interface"
        )
        expect(message).to eq("requires keyword `encoding:` not declared by the interface")
      end
    end
  end
end
