# frozen_string_literal: true

# Issue #1456 — `OpenStruct` field access is not `call.undefined-method`.
#
# ostruct defines each field as a per-instance singleton method and answers the rest through a private
# `method_missing`, so no signature can enumerate its surface. The only declaration rbs 4.2 carries is json's
# add-on reopening (`json_create` / `as_json` / `to_json`), and Rigor read that as the whole class.
# `data/core_overlay/ostruct.rbs` declares the hook pair, and `CheckRules::CORE_OVERLAY_OPEN_RECEIVERS` names the
# class as an open receiver.
#
# This file lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)" job runs.
require "spec_helper"

RSpec.describe "OpenStruct (#1456)" do
  describe "the RBS definition" do
    def definition(libraries)
      Rigor::Environment::RbsLoader.new(libraries: libraries).instance_definition("OpenStruct")
    end

    it "declares the private method_missing on an overlay module the class includes" do
      method = definition([])&.methods&.[](:method_missing)

      expect(method).to have_attributes(accessibility: :private)
      expect(method.defined_in.to_s).to eq("::RigorCoreOverlay::OpenStructMissing")
      expect(method.defs.map { |d| d.member.location.buffer.name.to_s })
        .to all(end_with("data/core_overlay/ostruct.rbs"))
    end

    it "keeps json's reopening of the class beside it" do
      methods = definition(["json"])&.methods

      expect(methods&.[](:method_missing)&.defined_in.to_s).to eq("::RigorCoreOverlay::OpenStructMissing")
      expect(methods.slice(:to_json, :as_json).transform_values { |m| m.defined_in.to_s })
        .to eq(to_json: "::OpenStruct", as_json: "::OpenStruct")
    end
  end

  describe "inference", type: :runner do
    def undefined_lines(source)
      analyze(source).diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:line)
    end

    def dumped_types(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      result.diagnostics.filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end
    end

    def issue_example
      <<~RUBY
        o = OpenStruct.new(name: "x")
        puts o.name
        o.age = 3
        puts o.age
      RUBY
    end

    # THE REPORTED FALSE POSITIVE, as the issue wrote it.
    it "does not report the issue's field reads and writes" do
      expect(undefined_lines(%(require "ostruct"\n#{issue_example}))).to be_empty
    end

    it "does not report them with json required beside ostruct" do
      expect(undefined_lines(%(require "ostruct"\nrequire "json"\n#{issue_example}))).to be_empty
    end

    it "does not report OpenStruct's own undeclared methods" do
      expect(undefined_lines(<<~RUBY)).to be_empty
        require "ostruct"
        o = OpenStruct.new(name: "x")
        o.to_h
        o[:name]
        o.dig(:name)
        o.each_pair { |k, v| [k, v] }
        o.respond_to?(:name)
      RUBY
    end

    # Positive control: the class is not degraded to `Dynamic[top]` — json's declared `to_json` still types,
    # and only the undeclared field reads fall to `Dynamic`.
    it "keeps json's declared methods typed and types a field read as Dynamic" do
      expect(dumped_types(<<~RUBY)).to eq(["OpenStruct", "String", "Dynamic[top]"])
        o = OpenStruct.new(name: "x")
        dump_type(o)
        dump_type(o.to_json)
        dump_type(o.name)
      RUBY
    end

    # Review round 1 of #1982 — a project `sig/` that declares the hook pair on `OpenStruct` itself is a correct
    # hand-written signature. A `def method_missing` directly on the overlay's `class OpenStruct` collided with it
    # (`RBS::DuplicatedMethodDefinitionError`): a `rbs.coverage.definition-build-failed` row and the whole class
    # degraded to `Dynamic[top]`. The overlay's module is an ancestor the project's member overrides.
    it "lets a project sig/ declare the hook pair without a build failure or degradation" do
      sig = <<~RBS
        class OpenStruct
          private def method_missing: (Symbol mid, *untyped args) -> untyped
          private def respond_to_missing?: (Symbol | String mid, ?bool include_private) -> bool
        end
      RBS
      result = analyze(<<~RUBY, sig: { "ostruct.rbs" => sig })
        require "rigor/testing"
        include Rigor::Testing
        o = OpenStruct.new(name: "x")
        o.age = 3
        dump_type(o.to_json)
        dump_type(o.name)
      RUBY

      expect(result.diagnostics.map(&:qualified_rule)).not_to include(start_with("rbs.coverage"))
      expect(result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }).to be_empty
      dumps = result.diagnostics.map(&:message).grep(/\Adump_type: /).map { |m| m.delete_prefix("dump_type: ") }
      expect(dumps).to eq(["String", "Dynamic[top]"])
    end

    # A known cost of the open-receiver list, pinned so a change to it is deliberate: `unbounded_receiver_surface?`
    # also makes an inherited Object / Kernel signature unauthoritative for `call.wrong-arity`, and it does not
    # tell the singleton side from the instance side. These four report on a class Rigor reads as closed (the
    # mutation that drops `OpenStruct` from the list) and are silent here — lost true positives, not false ones.
    it "no longer reports inherited-signature arity or a singleton-side typo on OpenStruct" do
      result = analyze(<<~RUBY)
        o = OpenStruct.new(name: "x")
        o.freeze(1)
        o.respond_to?(:a, true, 3)
        o.instance_variable_get
        OpenStruct.no_such_method_zzz
      RUBY

      expect(result.diagnostics.select { |d| d.severity == :error }.map { |d| [d.line, d.qualified_rule] }).to be_empty
    end

    # Control: a project class with no RBS at all stays quiet, as before.
    it "leaves a class with no RBS unreported" do
      expect(undefined_lines(<<~RUBY)).to be_empty
        class Plain
          def a = 1
        end
        Plain.new.b
      RUBY
    end

    # Control: a fully declared class still reports what it does not answer.
    it "still reports an undeclared method on a fully declared class" do
      result = analyze(<<~RUBY, sig: { "ledger.rbs" => "class Ledger\n  def settle: () -> void\nend\n" })
        class Ledger
          def settle = nil
        end
        Ledger.new.settle
        Ledger.new.no_such_method_zzz
      RUBY
      expect(result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:line)).to eq([5])
    end
  end
end
