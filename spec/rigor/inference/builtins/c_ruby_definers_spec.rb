# frozen_string_literal: true

require "spec_helper"

# Issue #1740 — the CRuby definer record the refinement precedence walk proves a receiver's own method with. Each
# negative row is a method core RBS declares on the class while CRuby defines it on an ancestor or not at all.
RSpec.describe Rigor::Inference::Builtins::CRubyDefiners do
  it "lists a method CRuby defines on the class itself, aliases included" do
    expect(described_class.defines?("String", :center)).to be(true)
    expect(described_class.defines?("Integer", :digits)).to be(true)
    expect(described_class.defines?("Integer", :magnitude)).to be(true)
    expect(described_class.defines?("Comparable", :clamp)).to be(true)
  end

  it "does not list a method RBS redeclares on a subclass of its CRuby owner" do
    expect(described_class.defines?("Integer", :quo)).to be(false)
    expect(described_class.defines?("File", :to_path)).to be(false)
    expect(described_class.defines?("String", :clamp)).to be(false)
  end

  it "does not list a method CRuby registers only for RDoc" do
    expect(described_class.defines?("Random", :seed)).to be(false)
    expect(described_class.defines?("Random", :rand)).to be(false)
    expect(described_class.defines?("Random", :==)).to be(true)
  end

  # Each listed method the running Ruby has is owned by the class the catalogue names, so `refine` of an ancestor
  # cannot answer ahead of it. A method the running Ruby lacks is skipped: `Date#fill`, `#nth_kday?`, `#inspect_raw`
  # and `#marshal_dump_old` exist only in a debug build of `date_core.c`.
  # (`fatal` is a catalogued class name that is no constant; an `rdoc_only` entry is CRuby's RDoc-only registration.)
  it "lists only methods the running Ruby owns on the class it names" do
    require "date"
    misowned = Rigor::Inference::Builtins::MethodCatalog.topic_paths.flat_map do |path|
      classes = YAML.safe_load_file(path, permitted_classes: [Symbol])["classes"] || {}
      classes.flat_map do |name, klass|
        owner = runtime_module(name)
        next [] if owner.nil? || klass["rdoc_only"]

        listed_names(klass["instance_methods"]).concat(listed_names(klass["aliases"])).filter_map do |method|
          found = owned_method(owner, method)
          "#{name}##{method} (#{found.owner})" if found && found.owner != owner
        end
      end
    end
    expect(misowned).to eq([])
  end

  def listed_names(entries)
    (entries || {}).filter_map { |method, entry| method unless entry.is_a?(Hash) && entry["rdoc_only"] }
  end

  def runtime_module(name)
    found = Object.const_get(name)
    found.is_a?(Module) ? found : nil
  rescue NameError
    nil
  end

  def owned_method(owner, method)
    return nil unless owner.method_defined?(method) || owner.private_method_defined?(method)

    owner.instance_method(method)
  end

  it "answers false for a class no catalogue covers" do
    expect(described_class.defines?("Process::Status", :&)).to be(false)
    expect(described_class.defines?("Kernel", :center)).to be(false)
  end

  # Issue #1752 — the singleton side: `Integer.sqrt` is CRuby's own method of `Integer`'s singleton class, which a
  # refinement of `Object#sqrt` cannot answer ahead of; an instance method is not one.
  it "lists a singleton method CRuby defines on the class's singleton class, apart from its instance methods" do
    expect(described_class.singleton_defines?("Integer", :sqrt)).to be(true)
    expect(described_class.singleton_defines?("Integer", :digits)).to be(false)
    expect(described_class.defines?("Integer", :sqrt)).to be(false)
    expect(described_class.singleton_defines?("Struct", :members)).to be(false)
    expect(described_class.singleton_defines?("Kernel", :puts)).to be(false)
  end

  # Each listed singleton method the running Ruby has is owned by the class's own singleton class, so no refinement of
  # an ancestor answers ahead of it. A method the running Ruby lacks is skipped (`Date.test_civil` and the other
  # debug-build `date_core.c` methods).
  it "lists only singleton methods the running Ruby owns on the class's singleton class" do
    require "date"
    found = Rigor::Inference::Builtins::MethodCatalog.topic_paths.flat_map do |path|
      classes = YAML.safe_load_file(path, permitted_classes: [Symbol])["classes"] || {}
      classes.flat_map do |name, klass|
        owner = runtime_module(name)
        next [] if owner.nil? || klass["rdoc_only"]

        listed_names(klass["singleton_methods"]).filter_map do |method|
          method_found = owned_method(owner.singleton_class, method)
          [name, method, method_found.owner == owner.singleton_class] if method_found
        end
      end
    end
    expect(found.size).to be > 100
    expect(found.reject(&:last).map { |name, method, _| "#{name}.#{method}" }).to eq([])
  end
end
