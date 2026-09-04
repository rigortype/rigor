# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/reachability/scan"

# Issue #625 — Scan::Reference must record whether a reference is rooted with `::`.
RSpec.describe Rigor::Analysis::Reachability::Scan do
  def references_in(source)
    result = described_class.call(path: "lib/example.rb", source: source)
    expect(result).not_to be_nil
    result.references
  end

  describe "rooted reference tracking (#625)" do
    it "marks a bare constant reference as unrooted" do
      refs = references_in("class Caller\n  def run = Target.new\nend\n")
      expect(refs.map(&:as_written)).to eq(["Target"])
      expect(refs.first.rooted).to be(false)
    end

    it "marks a relative constant path as unrooted" do
      refs = references_in("class Caller\n  def run = Outer::Inner.new\nend\n")
      expect(refs.map(&:as_written)).to eq(["Outer::Inner"])
      expect(refs.first.rooted).to be(false)
    end

    it "marks a leading :: reference as rooted" do
      refs = references_in("class Caller\n  def run = ::Target.new\nend\n")
      expect(refs.map(&:as_written)).to eq(["Target"])
      expect(refs.first.rooted).to be(true)
    end

    it "marks a leading :: path reference as rooted" do
      refs = references_in("class Caller\n  def run = ::Outer::Inner.new\nend\n")
      expect(refs.map(&:as_written)).to eq(["Outer::Inner"])
      expect(refs.first.rooted).to be(true)
    end

    it "marks an unrooted superclass as unrooted" do
      refs = references_in("class Sub < Base\nend\n")
      expect(refs.map(&:as_written)).to eq(["Base"])
      expect(refs.first.rooted).to be(false)
    end

    it "marks a rooted superclass as rooted" do
      refs = references_in("class Sub < ::Base\nend\n")
      expect(refs.map(&:as_written)).to eq(["Base"])
      expect(refs.first.rooted).to be(true)
    end

    it "distinguishes rooted and unrooted references in the same scope" do
      source = <<~RUBY
        module MyApp
          class Caller
            def go
              Target.new
              ::Target.new
            end
          end
        end
      RUBY
      refs = references_in(source)
      expect(refs.map { |r| [r.as_written, r.rooted] }).to eq([
                                                                ["Target", false],
                                                                ["Target", true]
                                                              ])
    end
  end
end
