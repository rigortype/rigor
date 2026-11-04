# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# ADR-130 WD5 — sig-gen analyses with interface dispatch off, so a return read through a `Rigor::Plugin` interface
# member is not written into RBS: its output is what erasure gives. The note's case is a plugin `prepare` returning
# `_FactStore#publish`'s `nil`.
RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def candidates
    write_fixture("sig/holder.rbs", <<~RBS)
      module Rigor
        module Plugin
          interface _ProbeStore
            def publish: () -> nil
          end
        end
      end

      class Holder
        attr_reader store: Rigor::Plugin::_ProbeStore
      end
    RBS
    path = write_fixture("lib/holder.rb", "class Holder\n  def prepare = store.publish\nend\n")
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => [path], "signature_paths" => [File.join(tmpdir, "sig")])
    )
    described_class.new(configuration: configuration, paths: [path]).run
  end

  def prepare_row(rows) = rows.find { |row| row.class_name == "Holder" && row.method_name == :prepare }

  it "writes no return read through a plugin-interface member" do
    row = prepare_row(candidates)

    expect(row.rbs).to be_nil
    expect([row.classification, row.skip_reason]).to eq(%i[skipped untyped_return])
  end

  # The control: the same run with the switch made a no-op writes the interface member's `nil`.
  it "would write the member's return with dispatch on" do
    allow(Rigor::Inference::MethodDispatcher::RbsDispatch).to receive(:without_interface_dispatch).and_yield

    expect(prepare_row(candidates).rbs).to eq("def prepare: () -> nil")
  end
end
