# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #1778 — `data/core_overlay/hash.rbs` declares CRuby's `Hash.ruby2_keywords_hash?` and `Hash.ruby2_keywords_hash`
# through a module `Hash` extends, so the singleton methods resolve on every rbs release.
#
# No rbs release through 4.2 declares either method, so `Hash.ruby2_keywords_hash?({})` reported
# `call.undefined-method` on correct code. The inference half is in `spec/integration/hash_ruby2_keywords_spec.rb`.
#
# This file lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)" job runs: a
# broken overlay degrades `Hash`'s whole singleton surface on that line.
require "spec_helper"

RSpec.describe "Hash.ruby2_keywords_hash? and Hash.ruby2_keywords_hash (core overlay)" do
  let(:loader) { Rigor::Environment::RbsLoader.new(libraries: []) }

  def hash_singleton_methods
    loader.singleton_definition("Hash")&.methods
  end

  def method_type_strings(name)
    hash_singleton_methods[name].method_types.map(&:to_s)
  end

  it "declares both singleton methods from the core overlay" do
    expect(method_type_strings(:ruby2_keywords_hash?)).to eq(["(::Hash[untyped, untyped] hash) -> bool"])
    expect(method_type_strings(:ruby2_keywords_hash)).to eq(["[K, V] (::Hash[K, V] hash) -> ::Hash[K, V]"])
  end

  it "declares them through the overlay file, not a direct def" do
    %i[ruby2_keywords_hash? ruby2_keywords_hash].each do |name|
      definitions = hash_singleton_methods[name].defs
      expect(definitions.map { |definition| definition.member.location.buffer.name.to_s })
        .to all(end_with("data/core_overlay/hash.rbs"))
      expect(definitions.map { |definition| definition.implemented_in.to_s })
        .to all(eq("::RigorCoreOverlay::HashRuby2Keywords"))
    end
  end

  it "leaves Hash's upstream singleton methods buildable" do
    expect(hash_singleton_methods.keys).to include(:new, :[], :try_convert, :ruby2_keywords_hash?, :ruby2_keywords_hash)
  end

  # A direct declaration from elsewhere (a project `sig/`, or a later rbs release) overrides the extended module's
  # method instead of raising `DuplicatedMethodDefinitionError` and degrading `Hash`'s singleton surface.
  describe "a direct declaration of the same method" do
    let(:sig_dir) { Dir.mktmpdir("rigor-hash-ruby2-keywords-") }
    let(:loader) { Rigor::Environment::RbsLoader.new(libraries: [], signature_paths: [sig_dir]) }

    after { FileUtils.rm_rf(sig_dir) }

    before do
      File.write(File.join(sig_dir, "hash.rbs"), <<~RBS)
        class Hash[unchecked out K, unchecked out V]
          def self.ruby2_keywords_hash?: (untyped) -> true
        end
      RBS
    end

    it "lets the direct signature stand and keeps Hash's other singleton methods" do
      expect(method_type_strings(:ruby2_keywords_hash?)).to eq(["(untyped) -> true"])
      expect(hash_singleton_methods.keys).to include(:try_convert, :ruby2_keywords_hash)
    end
  end
end
