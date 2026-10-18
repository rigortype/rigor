# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #1833 — a file that adds or drops only a class mark (`Scope::DiscoveryIndex`'s object-extended or refined mark)
# declares nothing a consumer read, so before the `mark:<last segment>` key a warm recheck served the consumer's old
# report. The oracle is a full `--no-cache` run of the same tree, as in `possible_definer_incremental_spec.rb`.
RSpec.describe "class marks — incremental" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  def rules = %w[call.wrong-arity call.undefined-method]

  def diagnostics(list)
    list.select { |d| rules.include?(d.rule) }.map { |d| [File.basename(d.path), d.line] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    diagnostics(guarded_run(runner).diagnostics)
  end

  # `edits` maps a file name to its new source, or to nil to delete it.
  def warm_and_cold(files, edits)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      session = session_for(dir)
      baseline = diagnostics(guarded_baseline(session))
      edits.each do |name, source|
        path = File.join(dir, name)
        source.nil? ? File.delete(path) : File.write(path, source)
      end
      [baseline, diagnostics(guarded_recheck(session).diagnostics), full_run(dir)]
    end
  end

  shared_examples "a mark-only file" do |reported_without_mark:|
    it "re-checks the consumer when the file appears" do
      baseline, warm, cold = warm_and_cold(base, "mark.rb" => mark)

      expect(baseline).to eq(reported_without_mark)
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end

    it "re-checks the consumer when the file goes" do
      baseline, warm, cold = warm_and_cold(base.merge("mark.rb" => mark), "mark.rb" => nil)

      expect(baseline).to eq([])
      expect(cold).to eq(reported_without_mark)
      expect(warm).to eq(cold)
    end
  end

  # `SourceArity#object_extension_may_shadow?` reads every bucket for an object-extended module defining the name.
  describe "an extend in a method body" do
    let(:base) do
      { "own.rb" => "module Helper\n  def center(a, b, c) = 1\nend\nclass Own\n  def center(a) = a\nend\n",
        "use.rb" => "Own.new.center(1, 2, 3)\n" }
    end
    let(:mark) { "def go(o) = o.extend(Helper)\n" }

    it_behaves_like "a mark-only file", reported_without_mark: [["use.rb", 1]]
  end

  # The refinement own-definer proof (`RefinedDispatch::OwnMethod#object_prepended?`).
  describe "a singleton prepend on an object" do
    let(:base) do
      { "rc.rb" => "module RC; refine(Comparable) { def ljust(a, b, c) = :cmp }; end\n",
        "use.rb" => "using RC\n\"x\".ljust(1, 2, 3)\n" }
    end
    let(:mark) { "Object.new.singleton_class.prepend(Comparable)\n" }

    it_behaves_like "a mark-only file", reported_without_mark: [["use.rb", 2]]
  end

  # `ResolutionChain::Relevance` keeps `MyS`'s chain undischarged while `String` carries the refined mark, so `size`
  # types `Dynamic[top]`; a cold run without the `refine` answers `Integer`, which has no `zzz`.
  describe "a refined mark vanishing" do
    let(:files) do
      { "a.rb" => "class MyS < String; end\n",
        "r.rb" => "module R\n  refine(String) { def foo = 1 }\nend\n",
        "use.rb" => "MyS.new(\"a\").size.zzz\n" }
    end

    it "re-checks the consumer when the refine goes" do
      baseline, warm, cold = warm_and_cold(files, "r.rb" => "module R\nend\n")

      expect(baseline).to eq([])
      expect(cold).to eq([["use.rb", 1]])
      expect(warm).to eq(cold)
    end

    it "re-checks the consumer when the refine comes back" do
      baseline, warm, cold = warm_and_cold(files.merge("r.rb" => "module R\nend\n"), files)

      expect(baseline).to eq([["use.rb", 1]])
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end
  end

  describe "a mark added to a file that declares something else" do
    let(:files) do
      { "rc.rb" => "module RC; refine(Comparable) { def ljust(a, b, c) = :cmp }; end\n",
        "other.rb" => "class Other; end\n",
        "use.rb" => "using RC\n\"x\".ljust(1, 2, 3)\n" }
    end
    let(:marked) { "class Other; end\nObject.new.singleton_class.prepend(Comparable)\n" }

    it "re-checks the consumer when the mark is added" do
      baseline, warm, cold = warm_and_cold(files, "other.rb" => marked)

      expect(baseline).to eq([["use.rb", 2]])
      expect(cold).to eq([])
      expect(warm).to eq(cold)
    end

    it "re-checks the consumer when the mark is taken out" do
      baseline, warm, cold = warm_and_cold(files.merge("other.rb" => marked), files)

      expect(baseline).to eq([])
      expect(cold).to eq([["use.rb", 2]])
      expect(warm).to eq(cold)
    end
  end

  # Guards: these marks come with a `singleton_class_sources` or `class_sources` entry for the marked class, so the
  # class-declaration diff already fired `class:<last segment>` for them before issue #1833.
  describe "marks that also declare the class" do
    describe "a send of define_method" do
      let(:base) do
        { "own.rb" => "class Own\n  def center(a) = a\nend\n", "use.rb" => "Own.new.center(1, 2, 3)\n" }
      end
      let(:mark) { "Own.send(:define_method, :zz) { }\n" }

      it_behaves_like "a mark-only file", reported_without_mark: [["use.rb", 1]]
    end

    describe "a remove_method on a core class under a refinement" do
      let(:base) do
        { "ro.rb" => "module RO; refine(Object) { def center(a, b, c) = 1 }; end\n",
          "use.rb" => "using RO\n\"x\".center(1, 2, 3)\n" }
      end
      let(:mark) { "String.remove_method(:center)\n" }

      it_behaves_like "a mark-only file", reported_without_mark: [["use.rb", 2]]
    end
  end

  # Issue #1833 — a dynamic mark on a NAMESPACE CANDIDATE of the superclass written in a `class Sub < Foo` header.
  # Inside `module N`, the walker records `module N; Foo.send(:define_method, …); end` on BOTH `N::Foo` and `Foo`,
  # and the `:arity` resolver resolves `Foo` to `N::Foo` first because its bucket now `declares_surface?`. `N::Foo`
  # has no declaring file, so the chain truncates and `SourceArity` declines. Before this lane the
  # `DiscoveryIndex.declares_surface?` read bypassed `parameter_envelopes_of` and recorded no `mark:<last segment>`
  # edge, so a warm run after the mark file appeared or vanished kept its old answer.
  describe "a dynamic mark on a namespace candidate of a header's superclass" do
    let(:base) do
      { "foo.rb" => "class Foo\n  def run(a) = a\nend\n",
        "n.rb" => "module N\n  class Sub < Foo\n  end\nend\n",
        "use.rb" => "N::Sub.new.run(1, 2)\n" }
    end
    let(:mark) { "module N\n  Foo.send(:define_method, :zz) { }\nend\n" }

    it_behaves_like "a mark-only file", reported_without_mark: [["use.rb", 1]]
  end
end
