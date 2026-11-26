# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::SingletonClassSources` names the constants whose singleton side a file writes
# to without declaring them (#1752, #1941). The examples hand `record_singleton_class_sources` a parsed snippet, a
# path and a table, and read the table: no index is built and no body evaluated.
# `spec/integration/incremental_receiver_singleton_write_spec.rb` and
# `spec/rigor/analysis/class_mark_incremental_spec.rb` pin what an incremental run makes of the table.
RSpec.describe Rigor::Inference::ScopeIndexer::SingletonClassSources do
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  def record(source, path = "a.rb", sources = {})
    described_class.record_singleton_class_sources(sources, path, Prism.parse(source).value)
    sources
  end

  # The constants a snippet is filed under.
  def names(source) = record(source).keys

  describe "the table" do
    it "files each constant under the path it was handed, as a Set, and adds to the table it was handed" do
      sources = record("class << X; end\n")

      expect(sources).to eq("X" => Set["a.rb"])
      expect(record("class << X; end\ndef Y.z; end\n", "b.rb", sources)).to equal(sources)
      expect(sources).to eq("X" => Set["a.rb", "b.rb"], "Y" => Set["b.rb"])
    end

    it "files a constant once, however many of the three forms name it" do
      expect(record("class << X; end\ndef X.y; end\nX.extend(M)\n")).to eq("X" => Set["a.rb"])
    end

    it "files nothing for a program with none of the three" do
      expect(record("class A; def m = 1; end\nx = 1\n")).to eq({})
    end
  end

  describe "a `class <<` body" do
    it "names the constant its operand reads or writes, and nothing for any other operand" do
      expect(names("class << Const; end\nclass << A::B; end\nclass << K = make; end\n")).to eq(%w[Const A::B K])
      expect(names("class << self; end\nclass << make; end\nclass << (K = make); end\n")).to eq([])
    end

    it "is walked for what it holds, under the prefix around it" do
      expect(names("class << X; class << Y; end; Z.extend(M); end\n")).to eq(%w[X Y Z])
    end
  end

  describe "a `def` with a receiver" do
    it "names a constant receiver, and nothing for `self`, a local or a parenthesised path" do
      expect(names("def D.own; end\nmodule M; def E.own; end; end\n")).to eq(%w[D E])
      expect(names("def self.own; end\ndef x.own; end\ndef (M::E).own; end\ndef plain; end\n")).to eq([])
    end
  end

  describe "a call on a constant" do
    it "names the receiver of `singleton_class` and of a call that may rewrite its singleton side" do
      source = "A.singleton_class\nB.define_singleton_method(:x) { }\nC.extend(M)\nD.instance_eval { }\n" \
               "E.send(:extend, M)\nF.attr_accessor :x\nG::H.include(M)\n"

      expect(names(source)).to eq(%w[A B C D E F G::H])
    end

    it "names nothing for any other call, or for a receiver that is no constant" do
      expect(names("Const.foo\nConst.private_class_method :x\nx.extend(M)\nextend(M)\nx.singleton_class\n")).to eq([])
    end

    it "is walked for the calls in its receiver, its arguments and its block" do
      expect(names("X.extend(Y.singleton_class)\nfoo { class << Z; end }\nbar(class << W; end)\n")).to eq(%w[X Y Z W])
    end
  end

  describe "the name a constant is filed under" do
    it "is the declaration of the body it is written in when the file declares one, and the name as written if not" do
      declared = "module M; class E; end; class << E; end; def E.x; end; E.extend(X); end\n"

      expect(names(declared)).to eq(%w[M::E])
      expect(names("module M; class << E; end; def F.x; end; G.extend(X); end\n")).to eq(%w[E F G])
    end

    it "is the name as written for a rooted path, and the body's own name for the class it is written in" do
      expect(names("module M; class E; end; class << ::E; end; end\n")).to eq(%w[E])
      expect(names("class A; class << A; end; def A.x; end; end\n")).to eq(%w[A])
    end

    it "is resolved in the body a `def` or a `class <<` sits in, which push no prefix" do
      source = "module M; class E; end; class F; def m = E.extend(X); class << self; def E.y; end; end; end; end\n"

      expect(names(source)).to eq(%w[M::E])
    end
  end

  describe "a `class` or `module` header" do
    it "is walked through its body alone: the superclass is not walked" do
      expect(names("class A < (class << S; self; end); B.extend(M); end\n")).to eq(%w[B])
      expect(names("class A < B.extend(M); end\n")).to eq([])
    end

    # Prism recovers `class foo` as a header whose path is a call: it names no constant, so nothing below it is
    # filed under a name the header could not spell.
    it "is not walked when it names no constant" do
      root = Prism.parse("class foo; class << X; end; end\n").value
      sources = {}

      expect(root.statements.body.first.constant_path).to be_a(Prism::CallNode)
      described_class.record_singleton_class_sources(sources, "a.rb", root)
      expect(sources).to eq({})
    end

    it "is skipped without a body" do
      expect(names("class A; end\nmodule M; end\nX.extend(M)\n")).to eq(%w[X])
    end
  end

  # What another file of `lib/` calls: `ScopeIndexer.record_file_positions`. A second name here is a new way into
  # the module.
  it "exposes the entry alone, and no constant" do
    expect(described_class.singleton_methods(false)).to eq([:record_singleton_class_sources])
    expect(described_class.constants(false)).to eq([])
  end

  it "leaves none of its 4 functions on ScopeIndexer, public or private" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(4)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays, and allows four. This one calls
  # two: the constant a `class <<` operand or a receiver names, and whether a call may rewrite a singleton side.
  it "calls two functions of the indexer, at three sites" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/singleton_class_sources.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq(%i[singleton_receiver_constant_name surface_rewriting_call? singleton_receiver_constant_name])
  end

  it "is what the cross-file fold files a file's singleton-class sources with" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "writer.rb")
      File.write(path, "class << Base; end\ndef Other.x; end\n")

      expect(indexer.discovered_def_index_for_paths([path])[:singleton_class_sources])
        .to eq("Base" => Set[path], "Other" => Set[path])
    end
  end

  # The module reads none of the indexer's constants and calls two of its functions, which `scope_indexer.rb`
  # defines: the file requires what else it names, and until the indexer has loaded it answers only for a program
  # that asks neither.
  def alone_probe
    <<~RUBY
      require "rigor/inference/scope_indexer/singleton_class_sources"
      sources = Rigor::Inference::ScopeIndexer::SingletonClassSources
      record = lambda do |source|
        table = {}
        sources.record_singleton_class_sources(table, "a.rb", Prism.parse(source).value)
        table.keys
      rescue NameError => e
        [e.class.name, e.name]
      end
      answers = ["module M; class A; def m = 1; def self.s = 2; end; end", "class << X; end", "def D.own; end",
                 "X.foo", "X.singleton_class"].map(&record)
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), defined?(Rigor::Inference::DeclarationWalk::Rules),
             defined?(Rigor::Source::ConstantPath), answers].inspect
    RUBY
  end

  it "loads without the indexer, with what it names, and answers only what needs nothing of the indexer" do
    lib = File.join(DeclarationFactSources::REPO_ROOT, "lib")
    out, err, status = RubyRun.capture("-I", lib, "-e", alone_probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, "constant", "constant", [[], ["NoMethodError", :singleton_receiver_constant_name], ' \
                      '["NoMethodError", :singleton_receiver_constant_name], ' \
                      '["NoMethodError", :surface_rewriting_call?], ' \
                      '["NoMethodError", :singleton_receiver_constant_name]]]')
  end
end
