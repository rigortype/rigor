# frozen_string_literal: true

# Issue #2174 — `RbsLoader#ruby_library_reopen?` counts as the project's only the user's configured
# `signature_paths:` and RBS synthesized from its source. The loader's full `signature_paths` also holds plugin,
# gem-shipped (`sig/` of a bundled gem), rbs-collection and overlay directories; a declaration there is the
# library's own, so a class it declares must keep reporting `call.undefined-method`
# (`spec/integration/rbs_inline_ruby_library_reopen_spec.rb` covers the rule end to end).

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/environment"

RSpec.describe Rigor::Environment::RbsLoader, "#ruby_library_reopen?" do
  around do |example|
    Dir.mktmpdir("rigor-ruby-library-reopen-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:user_sig) { File.expand_path("sig") }
  let(:library_sig) { File.expand_path("gems/matrix-0.4.3/sig") }

  before do
    FileUtils.mkdir_p([user_sig, library_sig])
    File.write(File.join(user_sig, "matrix.rbs"), "class Matrix\n  def mine: () -> Integer\nend\n")
    # Stands in for a gem-shipped or rbs-collection declaration of a library class.
    File.write(File.join(library_sig, "vector.rbs"), "class Vector\n  def inner_product: (Vector) -> Integer\nend\n")
  end

  def loader(required_features: ["matrix"])
    described_class.new(signature_paths: [user_sig, library_sig], project_signature_paths: [user_sig],
                        required_features: required_features)
  end

  it "answers true for a required library's class declared only under the user's signature paths" do
    expect(loader.ruby_library_reopen?("Matrix")).to be(true)
  end

  it "answers false for a library's class declared under a signature path the user did not configure" do
    expect(loader.ruby_library_reopen?("Vector")).to be(false)
  end

  it "answers false when the project's source requires no feature of the library" do
    expect(loader(required_features: ["json"]).ruby_library_reopen?("Matrix")).to be(false)
  end

  # The fallback `Environment.for_project` takes when its caller passes no `required_features:`.
  it "scans the project's source for the required features when none are passed" do
    FileUtils.mkdir_p("lib")
    File.write("lib/a.rb", "require \"matrix\"\n")
    environment = Rigor::Environment.for_project(root: Dir.pwd, signature_paths: [user_sig],
                                                 source_files: [File.expand_path("lib/a.rb")])

    expect(environment.rbs_loader.ruby_library_reopen?("Matrix")).to be(true)
  end
end
