# frozen_string_literal: true

require "spec_helper"

# The leaf rows are pinned by `dependency_rows_spec.rb`, and each thin method's wiring by `module_wiring_spec.rb`.
# What neither sees is whether an assembler puts a leaf's rows into the descriptor at all: dropping one `+ leaf` term
# from `build_run_dependency_descriptor` leaves every leaf spec green and serves a stale answer (an edit to a
# `pre_eval:` file outside `paths:` goes unseen). Each example stubs every leaf the assembler calls with a row of its
# own and asserts that the assembled descriptor carries every one of them, in the order the assembler lists them.
RSpec.describe "Runner descriptor assemblers" do
  let(:runner) { Rigor::Analysis::Runner.allocate }
  let(:file_entry) { Rigor::Cache::Descriptor::FileEntry }
  let(:glob_entry) { Rigor::Cache::Descriptor::GlobEntry }

  def file(tag) = file_entry.kind(path: "/sentinel/#{tag}")
  def glob(tag) = glob_entry.compute(root: "/sentinel/#{tag}", pattern: "*", mode: :names)

  def descriptor(files: [], globs: [])
    Rigor::Cache::Descriptor.new(files: files, globs: globs)
  end

  # Stubs each named private runner method to answer the one row tagged with its own name.
  def stub_files(*names)
    names.each { |name| allow(runner).to receive(name).and_return([file(name)]) }
  end

  def stub_globs(*names)
    names.each { |name| allow(runner).to receive(name).and_return([glob(name)]) }
  end

  describe "#build_run_dependency_descriptor" do
    before do
      stub_files(:analyzed_file_entries, :discovery_file_entries, :required_missing_entries,
                 :pre_eval_file_entries, :template_unit_file_entries, :root_presence_entries)
      stub_globs(:template_unit_glob_entries, :discovery_glob_entries, :bundle_sig_glob_entries,
                 :producer_watch_glob_entries)
      allow(runner).to receive(:plugin_boundary_rows)
        .and_return(descriptor(files: [file(:boundary)], globs: [glob(:boundary)]))
    end

    let(:rbs) { descriptor(files: [file(:rbs)], globs: [glob(:rbs)]) }
    let(:built) { runner.send(:build_run_dependency_descriptor, { files: [] }, rbs) }

    it "carries the rows of every file leaf, in the order the assembler lists them" do
      expect(built.files).to eq(
        %i[analyzed_file_entries discovery_file_entries required_missing_entries pre_eval_file_entries
           template_unit_file_entries rbs root_presence_entries boundary].map { |tag| file(tag) }
      )
    end

    it "carries the rows of every glob leaf, in the order the assembler lists them" do
      expect(built.globs).to eq(
        %i[rbs template_unit_glob_entries discovery_glob_entries bundle_sig_glob_entries boundary
           producer_watch_glob_entries].map { |tag| glob(tag) }
      )
    end
  end

  describe "#incremental_slot_rows" do
    before do
      runner.instance_variable_set(:@record_dependencies, true)
      runner.instance_variable_set(:@configuration, instance_double(Rigor::Configuration, pre_eval: []))
      runner.instance_variable_set(:@analysis_reads, { "a.rb" => [file(:read), glob(:read), file(:read)] })
      allow(runner).to receive_messages(pool_mode?: false, analysis_reads_attributed?: true)
      stub_files(:template_unit_file_entries, :kind_entries, :required_missing_entries)
      stub_globs(:template_unit_glob_entries)
      allow(runner).to receive(:plugin_boundary_rows)
        .and_return(descriptor(files: [file(:boundary)], globs: [glob(:boundary)]))
    end

    let(:slot) { runner.send(:incremental_slot_rows, roots: %w[lib]) }

    it "records the plugin boundary rows as the observed descriptor" do
      expect(slot.observed.files).to eq([file(:boundary)])
      expect(slot.observed.globs).to eq([glob(:boundary)])
    end

    it "records the template, kind and missing-require rows, and the template globs, as the derived descriptor" do
      expect(slot.derived.files).to eq(%i[template_unit_file_entries kind_entries required_missing_entries]
                                         .map { |tag| file(tag) })
      expect(slot.derived.globs).to eq([glob(:template_unit_glob_entries)])
    end

    it "records each file's own reads, split by row kind, as the by_file descriptors" do
      expect(slot.by_file.keys).to eq(%w[a.rb])
      expect(slot.by_file.fetch("a.rb").files).to eq([file(:read)])
      expect(slot.by_file.fetch("a.rb").globs).to eq([glob(:read)])
    end
  end

  describe "#baseline_dependency_rows" do
    before do
      runner.instance_variable_set(:@collect_stats, true)
      runner.instance_variable_set(:@analyzed_files, [:a])
      stub_files(:kind_entries, :discovery_file_entries, :required_missing_entries, :unanalysed_pre_eval_entries)
      stub_globs(:discovery_glob_entries, :bundle_sig_glob_entries)
      allow(runner).to receive_messages(pool_mode?: false, signature_root_candidates: [],
                                                  signature_rows: signature_pair)
    end

    let(:signature_pair) do
      [descriptor(files: [file(:own)], globs: [glob(:own)]), descriptor(files: [file(:pinned)], globs: [glob(:pinned)])]
    end

    let(:baseline) { runner.send(:baseline_dependency_rows, files: %w[a.rb]) }

    it "records the own signature, kind, discovery, missing-require and unanalysed `pre_eval:` rows as owned" do
      expect(baseline.owned.files).to eq(
        %i[own kind_entries discovery_file_entries required_missing_entries unanalysed_pre_eval_entries]
          .map { |tag| file(tag) }
      )
    end

    it "records the own signature globs and the discovery globs as owned" do
      expect(baseline.owned.globs).to eq([glob(:own), glob(:discovery_glob_entries)])
    end

    it "records the pinned signature rows and the bundle `sig/` listing as pinned" do
      expect(baseline.pinned.files).to eq([file(:pinned)])
      expect(baseline.pinned.globs).to eq([glob(:pinned), glob(:bundle_sig_glob_entries)])
    end
  end
end
