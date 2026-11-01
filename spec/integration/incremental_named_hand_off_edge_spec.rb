# frozen_string_literal: true

# Issue #2515 — a hand-off on a receiver the callee cannot type resolves by name to every user instance def of that
# name (`Scope#user_instance_def_owners`), so the caller's answer depends on the whole project's defs of the name and
# on whether a class names the owner as its superclass. The reads record `defines:<name>` and
# `subclass_of:<owner>`; without them an edit to a file the caller does not name leaves its served rows stale.
require "spec_helper"
require "tmpdir"

require "rigor/analysis/incremental_session"

RSpec.describe "incremental edges for a hand-off resolved by name (#2515)", type: :runner do
  let(:use_source) do
    <<~RUBY
      class Opts
        def self.a(parser, options, h) = h.c(parser, options)
      end
      class Help
        def run(argv)
          options = { format: "text" }
          OptionParser.new { |opts| Opts.a(opts, options, nil) }.parse!(argv)
          if options[:format] == "json"
            puts "{}"
          else
            puts "text"
          end
        end
      end
    RUBY
  end
  let(:writer) { 'parser.on("--format=FORMAT") { |value| options[:format] = value }' }
  let(:reader) { "puts(options.to_s)" }

  def klass(name, body, superclass: nil)
    "class #{name}#{" < #{superclass}" if superclass}\n  #{body}\nend\n"
  end

  def unrelated = klass("Unrelated", "def x = 1")

  def helper(name, body) = klass(name, "def c(parser, options) = #{body}")

  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def session_for(dir)
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), environment: shared_environment)
  end

  def rules_of(diagnostics) = diagnostics.map(&:rule).select { |rule| rule.start_with?("flow.") }.sort

  def full_rules(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    rules_of(guarded_run(runner).diagnostics)
  end

  # Writes `files` (name => source), analyses them, applies `edit` (name => source) and re-checks. Returns the
  # recheck and the cold rules of the edited tree.
  def recheck_after(files, edit)
    Dir.mktmpdir do |dir|
      files.each { |name, source| File.write(File.join(dir, name), source) }
      session = session_for(dir)
      expect(rules_of(guarded_baseline(session))).to eq(["flow.always-truthy-condition"])
      edit.each { |name, source| File.write(File.join(dir, name), source) }
      recheck = guarded_recheck(session)
      return [recheck, rules_of(recheck.diagnostics), full_rules(dir), File.join(dir, "use.rb")]
    end
  end

  it "re-checks the caller when a file starts defining the name with a writer" do
    files = { "use.rb" => use_source, "defs.rb" => helper("Helper", reader), "other.rb" => unrelated }
    recheck, incremental, cold, use = recheck_after(files, "other.rb" => helper("Other", writer))

    expect(recheck.affected.map { |path| File.basename(path) }).to include(File.basename(use))
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when a ninth def of the name crosses the cap" do
    defs = (1..8).map { |i| helper("Reader#{i}", reader) }.join
    files = { "use.rb" => use_source, "defs.rb" => defs, "other.rb" => unrelated }
    recheck, incremental, cold, use = recheck_after(files, "other.rb" => helper("Ninth", reader))

    expect(recheck.affected.map { |path| File.basename(path) }).to include(File.basename(use))
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when a file adds a subclass of the owner that overrides the hand-off target" do
    base = "class Helper\n  def c(parser, options) = really(parser, options)\n  " \
           "def really(parser, options) = #{reader}\nend\n"
    sub = "class Sub < Helper\n  def really(parser, options) = #{writer}\nend\n"
    files = { "use.rb" => use_source, "defs.rb" => base, "other.rb" => unrelated }
    recheck, incremental, cold, use = recheck_after(files, "other.rb" => sub)

    expect(recheck.affected.map { |path| File.basename(path) }).to include(File.basename(use))
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when a file adds a Class.new subclass that overrides the hand-off target" do
    base = "class Helper\n  def c(parser, options) = really(parser, options)\n  " \
           "def really(parser, options) = #{reader}\nend\n"
    sub = "Sub = Class.new(Helper) { def really(parser, options) = #{writer} }\n"
    files = { "use.rb" => use_source, "defs.rb" => base, "other.rb" => unrelated }
    recheck, incremental, cold, use = recheck_after(files, "other.rb" => sub)

    expect(recheck.affected.map { |path| File.basename(path) }).to include(File.basename(use))
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when a declared class becomes a Class.new subclass of the owner" do
    base = "class Helper\n  def c(parser, options) = really(parser, options)\n  " \
           "def really(parser, options) = #{reader}\nend\n"
    sub = "Sub = Class.new(Helper) { def really(parser, options) = #{writer} }\n"
    files = { "use.rb" => use_source, "defs.rb" => base, "other.rb" => "class Sub\nend\n" }
    recheck, incremental, cold, use = recheck_after(files, "other.rb" => sub)

    expect(recheck.affected.map { |path| File.basename(path) }).to include(File.basename(use))
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "re-checks the caller when a file assigns a constant a superclass names" do
    base = "class Helper\n  def c(parser, options) = really(parser, options)\n  " \
           "def really(parser, options) = #{reader}\nend\n" \
           "class Sub < H2\n  def really(parser, options) = #{writer}\nend\n"
    files = { "use.rb" => use_source, "defs.rb" => base, "other.rb" => unrelated }
    recheck, incremental, cold, use = recheck_after(files, "other.rb" => "H2 = Helper\n")

    expect(recheck.affected.map { |path| File.basename(path) }).to include(File.basename(use))
    expect(incremental).to eq([])
    expect(incremental).to eq(cold)
  end

  it "does not re-check the caller when an unrelated def appears" do
    files = { "use.rb" => use_source, "defs.rb" => helper("Helper", reader), "other.rb" => unrelated }
    recheck, incremental, cold, use = recheck_after(files, "other.rb" => klass("Unrelated", "def x = 1\n  def zzz = 2"))

    expect(recheck.affected.map { |path| File.basename(path) }).not_to include(File.basename(use))
    expect(incremental).to eq(["flow.always-truthy-condition"])
    expect(incremental).to eq(cold)
  end
end
