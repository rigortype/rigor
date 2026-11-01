# frozen_string_literal: true

# PR #2573 review — a class whose superclass is itself (`class S < ::M::S`, which sig-gen wrote for rails'
# `ActiveRecord::ConnectionAdapters::SchemaDumper`) sent rbs's `AncestorBuilder#singleton_ancestors`, which has no
# cycle check, into `SystemStackError`, and the whole run aborted. It is now this class's definition-build
# failure, reported like any other.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/environment"

RSpec.describe Rigor::Environment::RbsLoader do
  around do |example|
    Dir.mktmpdir("rigor-recursive-superclass-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "m.rbs"), "module M\n  class S < ::M::S\n  end\n  class N\n  end\nend\n")
      @root = dir
      example.run
    end
  end

  let(:loader) { Rigor::Environment.for_project(root: @root).rbs_loader }

  it "reports a self-superclass's singleton side as a RecursiveAncestorError build failure, not a stack overflow" do
    expect(loader.singleton_method(class_name: "M::S", method_name: :new)).to be_nil
    expect(loader.definition_build_failures.map { |row| row.first(2) }).to eq([["M::S", "RBS::RecursiveAncestorError"]])
  end

  it "records a stack overflow inside a singleton build as that class's build failure" do
    # Backstop: an ancestry loop the instance walk does not catch still must not abort the run.
    allow_any_instance_of(RBS::DefinitionBuilder).to receive(:build_singleton).and_raise(SystemStackError) # rubocop:disable RSpec/AnyInstance
    expect(loader.singleton_method(class_name: "M::N", method_name: :new)).to be_nil
    expect(loader.definition_build_failures.map { |row| row.first(2) }).to eq([["M::N", "SystemStackError"]])
  end

  it "records a stack overflow inside an instance build as that class's build failure" do
    allow_any_instance_of(RBS::DefinitionBuilder).to receive(:build_instance).and_raise(SystemStackError) # rubocop:disable RSpec/AnyInstance
    expect(loader.instance_method(class_name: "M::N", method_name: :x)).to be_nil
    expect(loader.definition_build_failures.map { |row| row.first(2) }).to eq([["M::N", "SystemStackError"]])
  end
end
