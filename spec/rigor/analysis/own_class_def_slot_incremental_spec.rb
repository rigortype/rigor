# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1615 (ADR-119 C2-e) — `StatementEvaluator#source_decomposition_projection` reads the receiver's OWN
# class's `deconstruct` / `deconstruct_keys` def and types its body. It used to take the raw def slot, so
#
# - a slot rebuilt from an ADR-85 seed bundle is a `DefHandle`, which has no `body`, and the read crashed or
#   went untyped on a warm recheck; and
# - the read filed no ADR-46 edge, so editing the DEFINING file did not re-check the reader.
#
# The oracle is a full `--no-cache` run of the same tree.
RSpec.describe "a pattern's source `deconstruct` read — incremental (#1615)" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  def sites(list)
    list.reject { |d| d.severity == :info }.map { |d| "#{File.basename(d.path)}:#{d.line}:#{d.rule}" }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    sites(guarded_run(runner).diagnostics)
  end

  def point_source(value) = "class Point\n  def deconstruct = #{value}\nend\n"

  # `a` is whatever `Point#deconstruct`'s first element is: an Integer here, so `upcase` is undefined on it.
  let(:reader) { "a_reader.rb" }
  let(:reader_source) { "case Point.new\nin [a, _]\n  a.upcase\nend\n" }
  let(:fires) { ["#{reader}:3:call.undefined-method"] }

  def write_tree(dir, value: "[1, 2]", reader_text: reader_source)
    File.write(File.join(dir, "z_point.rb"), point_source(value))
    File.write(File.join(dir, reader), reader_text)
  end

  it "re-checks the reader when the defining file is edited" do
    Dir.mktmpdir do |dir|
      write_tree(dir)
      session = session_for(dir)
      expect(sites(guarded_baseline(session))).to eq(fires)

      File.write(File.join(dir, "z_point.rb"), point_source('["x", "y"]'))
      warm = sites(guarded_recheck(session).diagnostics)

      expect(full_run(dir)).to eq([])
      expect(warm).to eq([])
    end
  end

  it "types the body of a def served from the seed bundle, as a full run does" do
    Dir.mktmpdir do |dir|
      write_tree(dir)
      session = session_for(dir)
      expect(sites(guarded_baseline(session))).to eq(fires)

      File.write(File.join(dir, reader), "#{reader_source}1\n")
      recheck = guarded_recheck(session)

      expect(recheck.reused).to include(File.join(dir, "z_point.rb"))
      expect(sites(recheck.diagnostics)).to eq(fires)
      expect(sites(recheck.diagnostics)).to eq(full_run(dir))
    end
  end
end
