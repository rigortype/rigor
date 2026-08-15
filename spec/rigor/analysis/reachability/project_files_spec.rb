# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "rigor/analysis/reachability/project_files"

# `rigor unused` harvests references from the whole project rather than only the analysed paths (ADR-102 WD7),
# which makes "the whole project" a question needing an answer. Reading a vendored checkout is wrong twice
# over: its code is not this project's, and on Rigor's own repository it is 77% of the files.
RSpec.describe Rigor::Analysis::Reachability::ProjectFiles do
  let(:root) { Dir.mktmpdir("rigor-project-files-") }

  after { FileUtils.remove_entry(root) if File.directory?(root) }

  def gitmodules(content)
    File.write(File.join(root, ".gitmodules"), content)
  end

  describe ".submodule_prefixes" do
    it "reads the declared paths" do
      gitmodules(<<~CONF)
        [submodule "references/rbs"]
        \tpath = references/rbs
        \turl = https://example.invalid/rbs.git
        [submodule "references/ruby"]
        \tpath = references/ruby
        \turl = https://example.invalid/ruby.git
      CONF
      expect(described_class.submodule_prefixes(root)).to eq(["references/rbs/", "references/ruby/"])
    end

    it "normalises a declared path that already ends in a slash" do
      gitmodules("[submodule \"x\"]\n\tpath = vendored/x/\n")
      expect(described_class.submodule_prefixes(root)).to eq(["vendored/x/"])
    end

    it "returns nothing when the checkout has no submodules" do
      expect(described_class.submodule_prefixes(root)).to eq([])
    end
  end

  describe ".own" do
    it "drops files inside a submodule" do
      gitmodules("[submodule \"references/ruby\"]\n\tpath = references/ruby\n")
      paths = ["lib/app.rb", "references/ruby/lib/set.rb", "references/ruby_helper.rb"]

      # `references/ruby_helper.rb` must survive: the prefix is a directory boundary, not a string prefix.
      expect(described_class.own(paths, root)).to eq(["lib/app.rb", "references/ruby_helper.rb"])
    end

    it "drops vendored trees" do
      paths = ["lib/app.rb", "vendor/bundle/gems/x/lib/x.rb", "node_modules/y/index.rb", "tmp/scratch.rb"]
      expect(described_class.own(paths, root)).to eq(["lib/app.rb"])
    end

    # The control: without this the two examples above would pass for a predicate that rejects everything.
    it "keeps ordinary project files" do
      paths = ["lib/app.rb", "app/models/talk.rb", "config/initializers/x.rb", "lib/tasks/y.rake"]
      expect(described_class.own(paths, root)).to eq(paths)
    end
  end
end
