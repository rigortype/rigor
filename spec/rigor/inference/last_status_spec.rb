# frozen_string_literal: true

require "spec_helper"
require "prism"

# Issue #1360 — `$?` is the thread's last child status: a subprocess that waits for its child sets it to a
# `Process::Status`, and a `wait` with `WNOHANG` or a `waitall` may set it back to nil.
RSpec.describe Rigor::Inference::LastStatus do
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.default) }
  let(:status_t) { Rigor::Type::Combinator.nominal_of("Process::Status") }

  def last_statement(source) = Prism.parse(source).value.statements.body.last

  # The indexed scope and node of the last statement of `source`.
  def indexed_last(source)
    tree = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: scope)
    node = tree.statements.body.last
    [node, index[node]]
  end

  describe ".sets?" do
    it "names a command, `system` on `Kernel`'s spellings, and a `Process` wait without flags" do
      ["`true`", "%x(true)", "`echo \#{x}`", "system('x')", "self.system('x')", "Kernel.system('x')",
       "::Kernel.system('x', out: nil)", "Process.wait", "Process.wait(pid)", "::Process.waitpid(pid)",
       "Process.wait2(pid)", "Process.waitpid2(pid)"].each do |source|
        expect(described_class.sets?(last_statement(source), scope)).to be(true), source
      end
    end

    it "does not name a wait with flags, a wait on another receiver, `spawn`, `last_status` or `IO.popen`" do
      ["Process.wait(pid, Process::WNOHANG)", "Process.wait(*args)", "Process.wait(...)", "cv.wait(mutex)",
       "Process.waitall", "spawn('x')", "Process.last_status", "IO.popen('x')", "io.system('x')",
       "Process.detach(pid)"].each do |source|
        expect(described_class.sets?(last_statement(source), scope)).to be(false), source
      end
    end

    # A program's own `system`, backtick or `wait` runs Ruby code in its place.
    it "does not name a subprocess call whose name the program defines" do
      ["def system(*) = true\nsystem('x')", "def `(cmd) = cmd\n`x`",
       "module Process; def self.wait(*) = nil; end\nProcess.wait(1)"].each do |source|
        node, node_scope = indexed_last(source)
        expect(described_class.sets?(node, node_scope)).to be(false), source
      end
      node, node_scope = indexed_last("def other = 1\nsystem('x')")
      expect(described_class.sets?(node, node_scope)).to be(true)
    end

    it "requires the `Process` constant to resolve to the core module" do
      tree = Prism.parse("module App; module Process; end; end\nmodule App; Process.wait(1); end").value
      index = Rigor::Inference::ScopeIndexer.index(tree, default_scope: scope)
      call = tree.statements.body.last.body.body.last
      expect(index[call].type_of(call.receiver).describe(:short)).to eq("singleton(App::Process)")
      expect(described_class.sets?(call, index[call])).to be(false)
      core = Prism.parse("module App; end\nmodule App; Process.wait(1); end").value
      core_index = Rigor::Inference::ScopeIndexer.index(core, default_scope: scope)
      core_call = core.statements.body.last.body.body.last
      expect(described_class.sets?(core_call, core_index[core_call])).to be(true)
    end
  end

  describe ".certainly_sets?" do
    it "reads a command in the receiver chain or an argument, and in parentheses" do
      ["`a`.strip", "`a`.lines.map(&:chomp)", "puts(`a`)", "log(x, system('y'))", "(`a`).size"].each do |source|
        expect(described_class.certainly_sets?(last_statement(source), scope)).to be(true), source
      end
    end

    it "does not read a command that may not run: in a block, a branch, a safe-navigation argument or a literal" do
      ["items.each { `a` }", "x&.y(`a`)", "ok && `a`", "ok ? `a` : nil", "[`a`]", "log(ok ? `a` : 1)"]
        .each do |source|
          expect(described_class.certainly_sets?(last_statement(source), scope)).to be(false), source
        end
    end
  end

  describe ".clears?" do
    it "names a wait that may pass `WNOHANG`, on any receiver, `waitall`, and a `send` naming either" do
      ["Process.wait(pid, Process::WNOHANG)", "Process.waitpid2(-1, flags)", "Process.wait(*args)",
       "Process.wait(...)", "cv.wait(mutex, 1)", "Process.waitall", "Process.send(:wait, pid, 1)",
       "Process.__send__('waitall')"].each do |source|
        expect(described_class.clears?(last_statement(source))).to be(true), source
      end
    end

    it "does not name a blocking wait, another call or a computed `send`" do
      ["Process.wait(pid)", "Process.wait", "cv.wait(mutex)", "system('x')", "obj.send(name, 1)",
       "obj.send(\"\\xff\")", "`x`"].each do |source|
        expect(described_class.clears?(last_statement(source))).to be(false), source
      end
    end

    it "is gathered for the file by the scope indexer" do
      _, clearing = indexed_last("def reap = Process.wait(-1, Process::WNOHANG)\nsystem('x')")
      _, plain = indexed_last("def run = Process.wait(1)\nsystem('x')")

      expect(clearing.discovery.clears_last_status).to be(true)
      expect(plain.discovery.clears_last_status).to be(false)
    end
  end

  describe ".after" do
    it "binds `$?` past a statement that certainly ran a subprocess, and nowhere in a file that may clear it" do
      node = last_statement("system('x')")

      expect(described_class.after(node, scope, scope).global(:$?)).to eq(status_t)
      expect(described_class.after(last_statement("log('x')"), scope, scope)).to equal(scope)
      clearing = scope.with_discovery(scope.discovery.with(clears_last_status: true))
      expect(described_class.after(node, clearing, clearing)).to equal(clearing)
    end
  end

  describe ".restore_unless_set" do
    it "keeps what an `ensure` clause bound, and otherwise takes what it entered with" do
      bound = scope.with_global(:$?, status_t)

      expect(described_class.restore_unless_set(scope, bound).global(:$?)).to eq(status_t)
      expect(described_class.restore_unless_set(bound, scope)).to equal(bound)
      expect(described_class.restore_unless_set(scope, scope)).to equal(scope)
      expect(described_class.restore_unless_set(bound, bound).global(:$?)).to eq(status_t)
    end
  end
end
