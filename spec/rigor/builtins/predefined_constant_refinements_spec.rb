# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Rigor::Builtins::PredefinedConstantRefinements do
  let(:non_empty_string) { Rigor::Type::Combinator.non_empty_string }
  let(:numeric_string)   { Rigor::Type::Combinator.numeric_string }

  describe ".lookup — tier 1: exact-value whitelist" do
    it "returns Constant[Math::PI] (Float)" do
      type = described_class.lookup("Math::PI")
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(Math::PI)
    end

    it "returns Constant[Math::E] (Float)" do
      type = described_class.lookup("Math::E")
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(Math::E)
    end

    it "returns Constant[Float] (not the broader Nominal[Float] from RBS)" do
      type = described_class.lookup("Math::PI")
      expect(type).not_to be_a(Rigor::Type::Nominal)
    end

    it "folds the IEEE 754 binary64 magnitude constants to their exact value" do
      {
        "Float::INFINITY" => Float::INFINITY,
        "Float::MAX" => Float::MAX,
        "Float::MIN" => Float::MIN,
        "Float::EPSILON" => Float::EPSILON
      }.each do |name, value|
        type = described_class.lookup(name)
        expect(type).to be_a(Rigor::Type::Constant), "expected #{name} to fold"
        expect(type.value).to eq(value)
      end
    end

    it "does NOT fold Float::NAN (non-reflexive == would break the Constant equality contract)" do
      # Float::NAN is a non-empty... it's not a String, so tier 2 also declines — the lookup falls through to the RBS
      # Nominal[Float].
      expect(described_class.lookup("Float::NAN")).to be_nil
    end
  end

  describe ".lookup — tier 2: the closed interpreter-constant table" do
    it "returns non-empty-string for RUBY_VERSION" do
      expect(described_class.lookup("RUBY_VERSION")).to eq(non_empty_string)
    end

    it "returns non-empty-string for Ruby::VERSION" do
      expect(described_class.lookup("Ruby::VERSION")).to eq(non_empty_string)
    end

    it "returns non-empty-string for RUBY_PLATFORM" do
      expect(described_class.lookup("RUBY_PLATFORM")).to eq(non_empty_string)
    end

    it "returns non-empty-string for Ruby::ENGINE" do
      expect(described_class.lookup("Ruby::ENGINE")).to eq(non_empty_string)
    end

    it "returns non-empty-string for RUBY_REVISION (git SHA — non-empty, non-numeric)" do
      expect(described_class.lookup("RUBY_REVISION")).to eq(non_empty_string)
    end

    it "returns non-empty-string for File::SEPARATOR" do
      expect(described_class.lookup("File::SEPARATOR")).to eq(non_empty_string)
    end

    it "returns non-empty-string for File::Separator (the capital-S alias core RBS also declares)" do
      # Both spellings name the same value, so a rule that fires on one MUST fire on the other; listing only the
      # screaming-case twin made `File::Separator.size == 0` stop reporting as always-false while `File::SEPARATOR`
      # still did.
      expect(described_class.lookup("File::Separator")).to eq(non_empty_string)
    end

    it "returns nil for RUBY_PATCHLEVEL (Integer constant — no String refinement)" do
      expect(described_class.lookup("RUBY_PATCHLEVEL")).to be_nil
    end

    it "returns nil for a project-defined constant absent from the analyzer process" do
      expect(described_class.lookup("MyProject::UNDEFINED_FOO")).to be_nil
    end

    it "returns nil for an unknown constant path" do
      expect(described_class.lookup("Nonexistent::CONSTANT")).to be_nil
    end
  end

  # Issue #680. The tier used to resolve whatever name reached it with `const_get` against the analyzer's own
  # runtime; the set of names it can answer for is now enumerated in Rigor's source, so no name read out of the
  # analysed program is ever resolved.
  describe ".lookup — the table is closed (#680)" do
    it "returns nil for a String constant that IS loaded in the analyzer but is not listed" do
      stub_const("RIGOR_SPEC_MIXED_CONST", "v1.2.3")
      expect(described_class.lookup("RIGOR_SPEC_MIXED_CONST")).to be_nil
    end

    it "returns nil for a loaded gem's VERSION (its value is the project's Gemfile.lock's to say)" do
      # RBS is in the analyzer's own bundle and genuinely loaded, so the old open walk answered for it — which
      # made the type depend on how Rigor itself was installed.
      expect(described_class.lookup("RBS::VERSION")).to be_nil
    end

    it "never invokes const_missing for a const_missing-resolved path (e.g. Digest::UUID)" do
      called = false
      probe = Module.new do
        define_singleton_method(:const_missing) do |_name|
          called = true
          raise LoadError, "library not found"
        end
      end
      stub_const("RigorSpecConstMissingProbe", probe)

      expect(described_class.lookup("RigorSpecConstMissingProbe::Whatever")).to be_nil
      expect(called).to be(false)
    end

    it "still folds the tier-1 table and the listed tier-2 names (the closure is not a blanket decline)" do
      expect(described_class.lookup("Math::PI")).to be_a(Rigor::Type::Constant)
      expect(described_class.lookup("RUBY_VERSION")).to eq(non_empty_string)
    end
  end

  # The load-time half. `.lookup` cannot reach these any more, but the walk that BUILDS the table still runs a
  # `const_get`, and the guard on it is what keeps a pending autoload from being executed — defence in depth for
  # the day a name is added to the list carelessly.
  describe "the load-time resolver" do
    let(:autoload_dir) { Dir.mktmpdir("rigor-spec-autoload-") }
    let(:marker_path)  { File.join(autoload_dir, "fired.marker") }
    let(:target_path)  { File.join(autoload_dir, "rigor_spec_autoload_target.rb") }
    let(:probe) do
      File.write(target_path, <<~RUBY)
        File.write(#{marker_path.dump}, "fired")
        RigorSpecAutoloadProbe::LOADED = "fired"
      RUBY
      Module.new.tap { |mod| mod.autoload(:LOADED, target_path) }
    end

    after { FileUtils.remove_entry(autoload_dir) if File.directory?(autoload_dir) }

    it "declines a REGISTERED-BUT-NOT-YET-TRIGGERED autoload instead of executing its target" do
      stub_const("RigorSpecAutoloadProbe", probe)

      expect(described_class.send(:runtime_string_value, "RigorSpecAutoloadProbe::LOADED")).to be_nil
      # Not merely "no value came back": the target file must not have RUN, and the registration must still be
      # pending. A crashed or short-circuited walk would satisfy the nil alone.
      expect(File.exist?(marker_path)).to be(false)
      expect(probe.autoload?(:LOADED)).to eq(target_path)
    end

    it "still reads a constant that is genuinely loaded (the decline is scoped to a pending autoload)" do
      stub_const("RIGOR_SPEC_LOADED_CONST", "v1.2.3")
      expect(described_class.send(:runtime_string_value, "RIGOR_SPEC_LOADED_CONST")).to eq("v1.2.3")
    end

    it "reads through an autoload that has already run (autoload? is nil once triggered)" do
      stub_const("RigorSpecAutoloadProbe", probe)
      probe.const_get(:LOADED) # trigger it explicitly, the way requiring the library would

      expect(probe.autoload?(:LOADED)).to be_nil
      expect(described_class.send(:runtime_string_value, "RigorSpecAutoloadProbe::LOADED")).to eq("fired")
    end

    it "returns nil rather than propagating when resolution raises a non-StandardError" do
      probe = Module.new do
        define_singleton_method(:const_defined?) { |_name, _inherit = true| true }
        define_singleton_method(:autoload?) { |_name| nil }
        define_singleton_method(:const_get) { |_name, _inherit = true| exit }
      end
      stub_const("RigorSpecExitingProbe", probe)

      expect(described_class.send(:runtime_string_value, "RigorSpecExitingProbe::BOOM")).to be_nil
    end

    it "classifies a numeric-literal value as numeric-string and anything else as non-empty-string" do
      expect(described_class.send(:classify_string, "42")).to eq(numeric_string)
      expect(described_class.send(:classify_string, "v1.2.3")).to eq(non_empty_string)
    end
  end

  # The gate from #680: analysing a REFERENCE must not drive the analyzer's runtime to autoload. Asserted through
  # a real run, on the autoload not having fired — a crashed run also produces no diagnostic.
  describe "analysing a reference to an autoload-registered constant", type: :runner do
    let(:autoload_dir) { Dir.mktmpdir("rigor-spec-autoload-run-") }
    let(:marker_path)  { File.join(autoload_dir, "fired.marker") }
    let(:target_path)  { File.join(autoload_dir, "rigor_spec_autoload_run_target.rb") }
    let(:probe) do
      File.write(target_path, <<~RUBY)
        File.write(#{marker_path.dump}, "fired")
        RigorSpecAutoloadRunProbe::LOADED = "fired"
      RUBY
      Module.new.tap { |mod| mod.autoload(:LOADED, target_path) }
    end

    after { FileUtils.remove_entry(autoload_dir) if File.directory?(autoload_dir) }

    it "leaves the autoload pending, and still refines the listed constants in the same file" do
      stub_const("RigorSpecAutoloadRunProbe", probe)
      result = analyze(<<~RUBY)
        require "rigor/testing"
        include Rigor::Testing
        dump_type(RigorSpecAutoloadRunProbe::LOADED)
        dump_type(RUBY_VERSION)
      RUBY

      # Must-still-succeed half: the run really analysed the file, and tier 2 still answers.
      expect(result.diagnostics.map(&:message)).to include(a_string_matching(/non-empty-string/))
      expect(File.exist?(marker_path)).to be(false)
      expect(probe.autoload?(:LOADED)).to eq(target_path)
    end
  end
end
