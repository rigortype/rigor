# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/sig_gen/generic_header_scan"

# #2603/#2605 — the run-wide view of the bare generic headers under the sig root, read before anything is written.
RSpec.describe Rigor::SigGen::GenericHeaderScan do
  let(:root) { Pathname(Dir.mktmpdir) }

  after { FileUtils.remove_entry(root) }

  def sig(name, body)
    path = root.join(name)
    FileUtils.mkdir_p(path.dirname)
    path.write(body)
    path.to_s
  end

  def scan
    described_class.scan(sig_root: root, spelling_for: ->(name) { { "Array" => "[unchecked out E]" }[name] })
  end

  it "clears a class for repair only when no bare opening of it, in any file, names a parameter" do
    clear = sig("a.rbs", "class Array\n  def a: () -> 1\nend\n")
    held = sig("b/held.rbs", "class Array\n  def h: () -> E\nend\n")

    expect(scan.repairs).to eq({})
    expect(scan.left_bare).to eq([{ class: "Array", targets: [clear, held],
                                    blocking: [{ target: held, names: ["E"] }] }])

    File.write(held, "class Array\n  def h: () -> ::E\nend\n")

    expect(scan.repairs).to eq({ "Array" => "[unchecked out E]" })
    expect(scan.repair_targets).to eq([clear, held])
    expect(scan.left_bare).to eq([])
  end

  it "skips a file that does not parse or is not UTF-8" do
    sig("broken.rbs", "class Array\n  def h: () -> E\n")
    sig("latin1.rbs", "class Array\n  # \xFF\n  def h: () -> E\nend\n".b)

    expect(scan.left_bare).to eq([])
  end
end
