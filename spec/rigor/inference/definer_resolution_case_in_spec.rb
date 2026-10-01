# frozen_string_literal: true

require "spec_helper"
require "prism"
require_relative "../../support/definer_resolution_case_in"

# ADR-119 WD2 — the call-site contract of `Inference::DefinerResolution.resolve`: its result is consumed only by
# an exhaustive `case/in` that is the call's own direct predicate, with exactly one arm for each of `Known(...)`,
# `UNKNOWN` and `ABSENT`, no `else` and no `in _`. `UNKNOWN` and `ABSENT` are both truthy, so a result that is
# assigned, returned, truth-tested or matched with a catch-all can fold a decline into a firing arm.
#
# The scan reads every file under `lib/` and `plugins/*/lib/` with Prism. It cannot see a call made through
# `send`, an alias or a variable holding the module. Its positive controls below show each rule firing.
RSpec.describe "DefinerResolution call sites" do
  def violations_in(*) = DefinerResolutionCaseIn.violations_in(*)

  let(:root) { File.expand_path("../../..", __dir__) }

  it "has no call site outside the exhaustive case/in shape" do
    paths = Dir[File.join(root, "{lib,plugins/*/lib}/**/*.rb")]
    expect(paths.map { |path| path.delete_prefix("#{root}/") }).to include("lib/rigor/inference/definer_resolution.rb")
    hits = paths.flat_map { |path| violations_in(File.read(path), path.delete_prefix("#{root}/")) }
    expect(hits).to be_empty, "DefinerResolution.resolve call sites that break the contract:\n  #{hits.join("\n  ")}"
  end

  describe "the scan itself" do
    let(:call) { "DefinerResolution.resolve(scope, 'C', :foo, :instance, question: :definer)" }
    let(:namespace) { "Rigor::Inference::DefinerResolution" }
    let(:good) do
      <<~RUBY
        case #{call}
        in #{namespace}::Known(answer:, owner:) then fire(answer, owner)
        in #{namespace}::UNKNOWN then nil
        in #{namespace}::ABSENT then nil
        end
      RUBY
    end

    def without_last_arm(source, replacement) = source.sub(/^in \S+::ABSENT then nil$/, replacement)

    it "accepts the three-arm case/in" do
      expect(violations_in(good)).to be_empty
    end

    it "flags an else arm" do
      expect(violations_in(good.sub(/^end$/, "else nil\nend"))).not_to be_empty
    end

    it "flags a catch-all `in _` arm" do
      expect(violations_in(good.sub(/^end$/, "in _ then nil\nend"))).not_to be_empty
    end

    it "flags a missing arm" do
      expect(violations_in(without_last_arm(good, ""))).not_to be_empty
    end

    it "accepts the module's declaration in its home file and flags a reopening elsewhere" do
      source = "module Rigor\n  module Inference\n    module DefinerResolution\n    end\n  end\nend\n"
      expect(violations_in(source, "lib/rigor/inference/definer_resolution.rb")).to be_empty
      expect(violations_in(source, "lib/rigor/other.rb")).not_to be_empty
    end

    it "flags a reference that is not a resolve call or a pattern" do
      sources = ["include DefinerResolution\n", "extend Rigor::Inference::DefinerResolution\n",
                 "m = DefinerResolution.method(:resolve)\n", "x = DefinerResolution::UNKNOWN\n",
                 "DefinerResolution.public_send(:resolve, 1)\n", "helper.public_send(:resolve, 1)\n"]
      expect(sources.map { |source| violations_in(source).empty? }).to all(be(false))
    end

    it "flags a result assigned to a local, stored in an instance variable, truth-tested or returned" do
      sources = ["found = #{call}\n", "@found = #{call}\n", "puts 1 if #{call}\n", "def f = #{call}\n"]
      expect(sources.map { |source| violations_in(source).empty? }).to all(be(false))
    end
  end
end
