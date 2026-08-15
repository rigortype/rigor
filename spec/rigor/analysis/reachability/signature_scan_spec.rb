# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/analysis/reachability/signature_scan"

# Issue #363 — a signature file both DECLARES and REFERENCES, and the reachability report must not confuse
# the two. Counting a declaration as a reference makes a class root itself, which on a project with generated
# RBS silently hides dead code; counting no references at all re-opens the false candidates the #345 probe
# measured. Every "does not reference" example below is therefore paired with one that must still reference.
RSpec.describe Rigor::Analysis::Reachability::SignatureScan do
  let(:dir) { Dir.mktmpdir("rigor-signature-scan-") }

  after { FileUtils.remove_entry(dir) if File.directory?(dir) }

  def write_signature(rbs)
    File.join(dir, "sig.rbs").tap { |path| File.write(path, rbs) }
  end

  def names_in(rbs)
    described_class.call(write_signature(rbs)).map(&:as_written)
  end

  describe "declarations do not reference themselves" do
    it "does not treat a class declaration as a reference to the class" do
      expect(names_in("class Orphan\nend\n")).not_to include("Orphan")
    end

    it "does not treat a module declaration as a reference to the module" do
      expect(names_in("module Orphan\nend\n")).not_to include("Orphan")
    end

    # The exact shape that hid rows on a real project: `rbs-inline` mirrors every class into `sig/`, so a
    # nested declaration must not root itself or its enclosing namespace either.
    it "does not reference a nested declaration or its namespace" do
      names = names_in("module ApplicationCable\n  class Channel\n  end\nend\n")
      expect(names).not_to include("ApplicationCable", "ApplicationCable::Channel", "Channel")
    end

    it "does not treat a constant or type-alias declaration as a reference to its own name" do
      expect(names_in("TIMEOUT: Integer\n")).not_to include("TIMEOUT")
      expect(names_in("type result = Integer\n")).not_to include("result")
    end
  end

  describe "positions are references" do
    it "references a superclass" do
      expect(names_in("class Talk < ApplicationRecord\nend\n")).to include("ApplicationRecord")
    end

    it "references a mixin argument" do
      expect(names_in("class Talk\n  include Publishable\nend\n")).to include("Publishable")
    end

    it "references parameter and return types" do
      names = names_in("class Talk\n  def bookmark_by: (User user) -> TalkBookmark?\nend\n")
      expect(names).to include("User", "TalkBookmark")
    end

    it "references a type inside a generic argument" do
      expect(names_in("class Talk\n  def all: () -> Array[Speaker]\nend\n")).to include("Speaker")
    end

    it "references an attribute's type" do
      expect(names_in("class Talk\n  attr_reader venue: Venue\nend\n")).to include("Venue")
    end

    it "references a constant declaration's type" do
      expect(names_in("DEFAULT: Venue\n")).to include("Venue")
    end
  end

  describe "nesting" do
    # A name written relative to an enclosing module has to reach the graph in a form its candidate walk can
    # resolve, or the reference is silently lost and the class becomes a false candidate.
    it "records a relative reference under its enclosing namespace as well as bare" do
      names = names_in("module Admin\n  class Report < Base\n  end\nend\n")
      expect(names).to include("Base", "Admin::Base")
    end

    it "strips a leading :: from an absolute name" do
      expect(names_in("class Talk < ::ApplicationRecord\nend\n")).to include("ApplicationRecord")
    end
  end

  describe "fail-soft" do
    it "returns nothing for an unparseable signature rather than raising" do
      expect(names_in("class Talk < <<<\n")).to eq([])
    end

    it "returns nothing for a missing file rather than raising" do
      expect(described_class.call(File.join(dir, "absent.rbs"))).to eq([])
    end
  end

  describe "the reference shape the graph consumes" do
    it "emits file-level references carrying the config role" do
      reference = described_class.call(write_signature("class Talk < ApplicationRecord\nend\n")).first

      expect(reference.from).to be_nil
      expect(reference.role).to eq(:config)
      expect(reference.nesting).to eq([])
    end
  end
end
