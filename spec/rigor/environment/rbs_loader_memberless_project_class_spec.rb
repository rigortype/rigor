# frozen_string_literal: true

# Issue #2438 — `RbsLoader#memberless_project_class?`: every declaration of the class is the project's own and
# none declares a member of the class itself. `call.undefined-method` reads it as "the singleton surface is not
# enumerable from this declaration" (`spec/integration/project_sidecar_open_singleton_spec.rb` covers the rule).

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment"

RSpec.describe Rigor::Environment::RbsLoader, "#memberless_project_class?" do
  around do |example|
    Dir.mktmpdir("rigor-memberless-project-class-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:user_sig) { File.expand_path("sig") }
  let(:library_sig) { File.expand_path("gems/lib-1.0/sig") }

  before do
    FileUtils.mkdir_p([user_sig, library_sig])
    File.write(File.join(user_sig, "ns.rbs"), <<~RBS)
      module NS
        VERSION: String
        class Foo
          def x: () -> 1
        end
      end
      module Mixed
        include Comparable
      end
      module Aliased
        alias self.a self.b
        def self.b: () -> 1
      end
      class Attr
        attr_reader name: String
      end
    RBS
    # Stands in for a gem-shipped or rbs-collection declaration: the library's own, not the project's.
    File.write(File.join(library_sig, "lib.rbs"), "module LibNS\n  class Inner\n  end\nend\n")
  end

  def loader
    described_class.new(signature_paths: [user_sig, library_sig], project_signature_paths: [user_sig])
  end

  it "answers true for a project namespace declaring only nested classes and constants" do
    expect(loader.memberless_project_class?("NS")).to be(true)
    expect(loader.memberless_project_class?("::NS")).to be(true)
  end

  it "answers false once a declaration lists a method, mixin, alias or attribute" do
    expect(%w[NS::Foo Mixed Aliased Attr].map { |name| loader.memberless_project_class?(name) })
      .to eq([false, false, false, false])
  end

  it "answers false when any declaration of the class has a member, even in another file" do
    File.write(File.join(user_sig, "ns_more.rbs"), "module NS\n  def self.known: () -> 1\nend\n")

    expect(loader.memberless_project_class?("NS")).to be(false)
  end

  it "answers false for a member-less module a library signature path declares" do
    expect(loader.memberless_project_class?("LibNS")).to be(false)
  end
end
