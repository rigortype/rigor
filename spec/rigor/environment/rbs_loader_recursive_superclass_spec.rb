# frozen_string_literal: true

# PR #2573 review — a class whose superclass is itself (`class S < ::M::S`, which sig-gen wrote for rails'
# `ActiveRecord::ConnectionAdapters::SchemaDumper`) sent rbs's `AncestorBuilder#singleton_ancestors`, which has no
# cycle check, into `SystemStackError`, and the whole run aborted. A superclass cycle is now this class's
# definition-build failure (`RBS::RecursiveAncestorError`); any other stack exhaustion stays fatal and is never
# memoised as a build failure.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/environment"

RSpec.describe Rigor::Environment::RbsLoader do
  # A legal 200-deep chain `D1 < D2 < … < D200`, the last one declaring `own`.
  def deep_chain
    classes = (1...200).map { |i| "class D#{i} < D#{i + 1}\nend\n" }.join
    "#{classes}class D200\n  def own: () -> Integer\nend\n"
  end

  let(:root) do
    Dir.mktmpdir("rigor-recursive-superclass-").tap do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "m.rbs"), "module M\n  class S < ::M::S\n  end\nend\n")
      File.write(File.join(dir, "sig", "ab.rbs"), "class A < B\nend\nclass B < A\nend\n")
      File.write(File.join(dir, "sig", "d.rbs"), deep_chain)
    end
  end
  let(:loader) { Rigor::Environment.for_project(root: root).rbs_loader }

  after { FileUtils.rm_rf(root) }

  def failures
    loader.definition_build_failures.map { |row| row.first(2) }
  end

  it "reports a self-superclass's singleton side as a RecursiveAncestorError build failure, not a stack overflow" do
    expect(loader.singleton_method(class_name: "M::S", method_name: :new)).to be_nil
    expect(failures).to eq([["M::S", "RBS::RecursiveAncestorError"]])
  end

  it "reports a two-class superclass cycle as a RecursiveAncestorError build failure" do
    expect(loader.singleton_method(class_name: "A", method_name: :new)).to be_nil
    expect(failures).to eq([["A", "RBS::RecursiveAncestorError"]])
  end

  it "resolves through a deep but acyclic superclass chain" do
    expect(loader.singleton_method(class_name: "D1", method_name: :new)).not_to be_nil
    expect(loader.instance_method(class_name: "D1", method_name: :own)&.method_types&.map(&:to_s))
      .to eq(["() -> ::Integer"])
    expect(failures).to be_empty
  end

  it "lets any other stack overflow abort, without memoising it as a build failure" do
    # The analysis recursed deep before the lazy build (the #2455 shape): fatal, and the class still builds once
    # the stack is free again.
    allow_any_instance_of(RBS::DefinitionBuilder).to receive(:build_singleton).and_raise(SystemStackError) # rubocop:disable RSpec/AnyInstance
    expect { loader.singleton_method(class_name: "D1", method_name: :new) }.to raise_error(SystemStackError)
    allow_any_instance_of(RBS::DefinitionBuilder).to receive(:build_singleton).and_call_original # rubocop:disable RSpec/AnyInstance
    expect(loader.singleton_method(class_name: "D1", method_name: :new)).not_to be_nil
    expect(failures).to be_empty
  end

  it "lets a stack overflow in an instance build abort, without memoising it" do
    allow_any_instance_of(RBS::DefinitionBuilder).to receive(:build_instance).and_raise(SystemStackError) # rubocop:disable RSpec/AnyInstance
    expect { loader.instance_method(class_name: "D200", method_name: :own) }.to raise_error(SystemStackError)
    allow_any_instance_of(RBS::DefinitionBuilder).to receive(:build_instance).and_call_original # rubocop:disable RSpec/AnyInstance
    expect(loader.instance_method(class_name: "D200", method_name: :own)).not_to be_nil
    expect(failures).to be_empty
  end
end
