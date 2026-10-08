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

  # The owner-is-not-the-class arm of `own_definer_node`: a prepended module's `deconstruct` is the one Ruby
  # dispatches to, so the own class's `deconstruct` must not be read as the pattern's decomposition. Ruby 4.0.5:
  #
  #   module P; def deconstruct = ["s", "t"]; end; class Point; prepend P; def deconstruct = [1, 2]; end
  #   case Point.new; in [a, _] then puts a.class, a; end   # => String, s   (so `a.upcase` is defined)
  #
  # Master read the own class's `[1, 2]` and fired `undefined method 'upcase' for 1`; the arm declines instead, so
  # the run reports nothing. The second example swaps the bodies: Ruby dispatches to P's `[1, 2]` and `a.upcase`
  # does raise, but the arm still declines (a conservative silence, not a truth claim). Only that example fails
  # when the owner check is removed, because the first one reads P's correct `["s", "t"]` by accident.
  describe "a prepended definer (ADR-119 C2-e)" do
    def prepended_tree(dir, module_returns:, class_returns:)
      File.write(File.join(dir, "z_point.rb"),
                 "module P\n  def deconstruct = #{module_returns}\nend\n" \
                 "class Point\n  prepend P\n  def deconstruct = #{class_returns}\nend\n")
      File.write(File.join(dir, reader), reader_source)
    end

    it "does not read the own class's deconstruct when a prepended module defines it" do
      Dir.mktmpdir do |dir|
        prepended_tree(dir, module_returns: '["s", "t"]', class_returns: "[1, 2]")

        expect(full_run(dir)).to eq([])
      end
    end

    it "declines to read the prepended module's deconstruct rather than the own class's" do
      Dir.mktmpdir do |dir|
        prepended_tree(dir, module_returns: "[1, 2]", class_returns: '["s", "t"]')

        expect(full_run(dir)).to eq([])
      end
    end
  end
end
