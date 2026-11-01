# frozen_string_literal: true

require "spec_helper"

# `full_gem_path` lives on `Gem::BasicSpecification` (rubygems' basic_specification.rb), which is what
# `Gem.loaded_specs` returns, and `Bundler::LockfileParser#dependencies` is a Hash keyed by gem name
# (bundler's lockfile_parser.rb). The vendored signatures under data/vendored_gem_sigs/ declared them the other way
# round, so a project calling either reported `call.undefined-method`, and Rigor's own code hid the report.
RSpec.describe "vendored gem signatures for Gem.loaded_specs and Bundler::LockfileParser (#2544)", type: :runner do
  def undefined_methods(source)
    analyze(source).diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  it "reads full_gem_path from a Gem.loaded_specs entry without a diagnostic" do
    expect(undefined_methods(<<~RUBY)).to eq([])
      spec = Gem.loaded_specs["x"]
      spec&.full_gem_path
      Gem.loaded_specs.each_value.find { |gem| "a".start_with?("\#{gem.full_gem_path}/") }
    RUBY
  end

  it "writes full_gem_path on a typed Gem::Specification, which inherits the writer from BasicSpecification" do
    expect(undefined_methods(<<~RUBY)).to eq([])
      spec = Gem::Specification.new
      spec.full_gem_path = "/tmp"
    RUBY
  end

  it "reads the lockfile's dependencies as a Hash keyed by gem name without a diagnostic" do
    expect(undefined_methods(<<~RUBY)).to eq([])
      parser = Bundler::LockfileParser.new(File.read("Gemfile.lock"))
      parser.dependencies.keys.map(&:to_s)
    RUBY
  end

  it "still reports a method neither declaration has, on each receiver (controls)" do
    messages = undefined_methods(<<~RUBY)
      Gem.loaded_specs["x"].no_such_gem_member_zz
      Bundler::LockfileParser.new("").dependencies.no_such_hash_member_zz
    RUBY

    expect(messages).to contain_exactly(
      a_string_matching(/no_such_gem_member_zz/), a_string_matching(/no_such_hash_member_zz/)
    )
  end
end
