# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #3407 — the cross-file publication census missed a constant target wherever Prism holds one outside a
# multiple assignment's direct lefts and rights, and a write in a class header. Another file's `LIMIT = 1` then
# published `1` although the second write rebinds `LIMIT` to something else, so `LIMIT.first` reported
# `call.undefined-method` on correct code. Each example pairs the rebinding form with a sibling `KEPT` the same
# file pair leaves published, so a census that retracted everything would fail it too.
RSpec.describe "the publication census's constant targets" do
  def analysed(files)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      configuration = Rigor::Configuration.new("paths" => [lib])
      yield guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
    end
  end

  # The `dump.type` answers for `LIMIT` and `KEPT` in a reader file, beside `a.rb`'s literals and `second_writer`.
  def duel(second_writer)
    analysed("a.rb" => "LIMIT = 1\nKEPT = :kept\n", "b.rb" => second_writer,
             "c.rb" => "Rigor.dump_type(LIMIT)\nRigor.dump_type(KEPT)\n") do |result|
      result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.sort_by(&:line)
            .map { |d| d.message.delete_prefix("dump_type: ") }
    end
  end

  it "reports nothing on the issue's repro, a constant under a splat target" do
    rules = analysed("a.rb" => "LIMIT = 1\n", "b.rb" => "x, *LIMIT = 2, 3\n", "c.rb" => "LIMIT.first\n") do |result|
      result.diagnostics.map(&:qualified_rule).grep(/\Acall\./)
    end

    expect(rules).to eq([])
  end

  {
    "a splat target" => "x, *LIMIT = 2, 3\n",
    "a nested target list" => "(LIMIT, y), z = [2, 3], 4\n",
    "a splat inside a nested target list" => "x, (y, *LIMIT) = 1, [2, 3]\n",
    "a `for` index" => "for LIMIT in [2]; end\n",
    "a `rescue => LIMIT` reference" => "begin\n  raise \"x\"\nrescue => LIMIT\nend\n",
    "a write in a class header's superclass expression" => "class Sub < (LIMIT = Object); end\n",
    "a write in a class header's path" => "class (LIMIT = Object)::Sub; end\n",
    "a write in a module header's path" => "module (LIMIT = Object)::Mod; end\n"
  }.each do |form, second_writer|
    it "retracts the other file's literal for #{form}" do
      expect(duel(second_writer)).to eq(["Dynamic[top]", ":kept"])
    end
  end
end
