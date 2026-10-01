# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1568 — `def.method-visibility-mismatch` reads the region a class's prepended modules occupy ahead of it
# (`CheckRules#own_private_definer_stands?`). A class that prepends nothing has an EMPTY region, and that read
# still depends on the class's declarations: a file that later gives it a `prepend` puts a definition ahead
# of the class's own private `def`, which is what a call reaches and what makes the diagnostic wrong.
#
# The oracle is a full `--no-cache` run of the same tree, and the driver is `IncrementalSession`, as in
# `class_existence_incremental_spec.rb`: `--verify-incremental` cannot see this class of gap.
RSpec.describe "prepend-region visibility read — incremental" do
  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir])
  end

  def shared_environment
    @shared_environment ||= Rigor::Environment.for_project
  end

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(
      configuration: configuration(dir), paths: [dir], environment: shared_environment
    )
  end

  def mismatches(diagnostics)
    found = diagnostics.select { |d| d.rule == "def.method-visibility-mismatch" }
    found.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: shared_environment
    )
    mismatches(guarded_run(runner).diagnostics)
  end

  it "re-checks a private-method call when another file gives the class a public prepended definition" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "class C\n  private\n\n  def foo = 1\nend\n")
      File.write(File.join(dir, "f.rb"), "module Factory\n  def self.build = C.new\nend\n")
      File.write(File.join(dir, "b.rb"), "Factory.build.foo\n")

      session = session_for(dir)
      expect(mismatches(guarded_baseline(session))).to eq([["b.rb", 1]])
      expect(full_run(dir)).to eq([["b.rb", 1]])

      # `P#foo` is public and sits ahead of `C#foo`: the call is correct, and a warm run must say so.
      File.write(File.join(dir, "d.rb"), "module P\n  def foo = 2\nend\n\nclass C\n  prepend P\nend\n")
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(File.join(dir, "b.rb"))
      expect(mismatches(recheck.diagnostics)).to eq([])
      expect(full_run(dir)).to eq([])
    end
  end

  it "keeps the call unaffected by a file that declares an unrelated class" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "class C\n  private\n\n  def foo = 1\nend\n")
      File.write(File.join(dir, "b.rb"), "C.new.foo\n")

      session = session_for(dir)
      guarded_baseline(session)

      File.write(File.join(dir, "d.rb"), "module P\n  def foo = 2\nend\n\nclass Other\n  prepend P\nend\n")
      recheck = guarded_recheck(session)
      expect(recheck.affected).not_to include(File.join(dir, "b.rb"))
      expect(mismatches(recheck.diagnostics)).to eq([["b.rb", 1]])
    end
  end

  # The read itself, without the reads a full call site brings along (the receiver's type and the dispatch both
  # file the class's edges too, which is why the two examples above cannot tell the missing edge apart): a class
  # that prepends nothing has an empty region, and finding it empty still depends on the class's declarations.
  it "files the class's declaring file as a dependency when the region it reads is empty" do
    index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
      discovered_classes: { "C" => true },
      discovered_class_sources: { "C" => ["app/c.rb:1"] }
    )
    scope = Rigor::Scope.empty.with_discovery(index)
    record = Rigor::Analysis::DependencyRecorder.record_for("app/reader.rb") do
      expect(Rigor::Analysis::CheckRules.send(:own_private_definer_stands?, scope, "C", :foo)).to be(true)
    end
    expect(record.sources.to_a + record.ancestry_sources.to_a).to include("app/c.rb")
  end
end
