# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #639 — a bare class REFERENCE (`Foo`, with no method call on it) resolved through
# `Reflection.constant_type_at`'s `discovered_classes` hit and recorded no ADR-46 edge, so deleting the
# declaring file left a warm `--incremental` run still answering `singleton(Foo)` while a full run answers
# the honest unresolved type. ADR-46 slice 1c had deliberately left the existence hit edgeless — a
# referencing file depends on the class's METHODS, not on its bare existence — and that holds right up to
# the deletion, which is the one change where existence is what moved.
#
# The oracle in every example is a full `--no-cache` run of the same tree; `--verify-incremental` cannot see
# this class of gap (its even-indexed subset re-analyses the consumer itself), so the discriminating driver
# is `IncrementalSession`, as for the #644 constant twin.
RSpec.describe "cross-file class existence — incremental" do
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

  # The existence answer verbatim: `singleton(Foo)` while a project file declares `Foo`, and the honest
  # unresolved `Dynamic[top]` once none does. Both arms are non-empty, so no comparison here can pass by two
  # coincidentally-equal empty sets the way a rule-name list could.
  def types(diagnostics)
    diagnostics.select { |d| d.rule == "dump.type" }.map { |d| d.message.sub("dump_type: ", "") }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, environment: shared_environment
    )
    types(guarded_run(runner).diagnostics)
  end

  def reader_source
    "Rigor.dump_type(Foo)\n"
  end

  it "re-checks the reader when the declaring file is DELETED, matching a full run" do
    Dir.mktmpdir do |dir|
      reader = File.join(dir, "a.rb")
      declaring = File.join(dir, "b.rb")
      File.write(reader, reader_source)
      File.write(declaring, "class Foo\nend\n")

      session = session_for(dir)
      expect(types(guarded_baseline(session))).to eq(["singleton(Foo)"])
      expect(full_run(dir)).to eq(["singleton(Foo)"])

      FileUtils.rm(declaring)
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(reader)
      expect(types(recheck.diagnostics)).to eq(["Dynamic[top]"])
      expect(full_run(dir)).to eq(["Dynamic[top]"])
    end
  end

  it "re-checks the reader when the declaring file APPEARS" do
    # The miss-side `class:` negative edge, unchanged by this fix and kept here as the must-fire counterpart
    # to the delete above: the pair proves neither direction passes on two coincidentally-empty sets.
    Dir.mktmpdir do |dir|
      reader = File.join(dir, "a.rb")
      File.write(reader, reader_source)

      session = session_for(dir)
      expect(types(guarded_baseline(session))).to eq(["Dynamic[top]"])

      File.write(File.join(dir, "b.rb"), "class Foo\nend\n")
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(reader)
      expect(types(recheck.diagnostics)).to eq(["singleton(Foo)"])
      expect(full_run(dir)).to eq(["singleton(Foo)"])
    end
  end

  it "does not re-check the referent when the declaring file's BODY changes" do
    # The narrowness the `class:` name key buys, and the reason this is not a positive edge to the declaring
    # file: a bare reference's answer is the class's EXISTENCE, so editing a method inside the declaration
    # must leave the referent served from cache. A file edge would have re-checked every bare referent of
    # every class the file declares on any edit to it — the fan-out ADR-46 slice 1c was avoiding.
    Dir.mktmpdir do |dir|
      reader = File.join(dir, "a.rb")
      declaring = File.join(dir, "b.rb")
      File.write(reader, reader_source)
      File.write(declaring, "class Foo\n  def z\n    1\n  end\nend\n")

      session = session_for(dir)
      guarded_baseline(session)

      File.write(declaring, "class Foo\n  def z\n    2\n  end\nend\n")
      expect(guarded_recheck(session).affected).not_to include(reader)

      # ...while REMOVING the declaration from that same file does pull it in: the must-fire half, so the
      # comparison above cannot pass on a session that re-checks nothing at all.
      File.write(declaring, "def z\n  2\nend\n")
      recheck = guarded_recheck(session)
      expect(recheck.affected).to include(reader)
      expect(types(recheck.diagnostics)).to eq(["Dynamic[top]"])
      expect(full_run(dir)).to eq(["Dynamic[top]"])
    end
  end

  it "does not re-check a referent of an UNRELATED class" do
    Dir.mktmpdir do |dir|
      reader = File.join(dir, "a.rb")
      File.write(reader, reader_source)
      File.write(File.join(dir, "b.rb"), "class Foo\nend\n")

      session = session_for(dir)
      guarded_baseline(session)

      File.write(File.join(dir, "c.rb"), "class Unrelated\nend\n")
      expect(guarded_recheck(session).affected).not_to include(reader)
    end
  end
end
