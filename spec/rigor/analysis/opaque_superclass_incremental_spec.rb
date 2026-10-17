# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #1624 across files. The typing read's `bot` exception declines on a chain whose last class has a superclass the
# tables cannot follow (`class Media < Class.new(Base)`), and applies once the superclass is the constant `Base`,
# whose `fail_with` raises: the caller in another file then narrows `count` past the guard and stops reporting.
# The warm run must re-check that caller when the file declaring the superclass changes it. The oracle is a full
# `--no-cache` run of the same tree; the driver is `IncrementalSession`, as in
# `typing_bot_exception_incremental_spec.rb`.
RSpec.describe "a superclass the tables cannot follow — incremental (#1624)" do
  def configuration(dir) = Rigor::Configuration.new("paths" => [dir])

  def shared_environment = (@shared_environment ||= Rigor::Environment.for_project)

  def reported(list)
    list.reject { |d| d.severity == :info }.map { |d| [File.basename(d.path), d.line, d.rule] }.sort
  end

  def full_run(dir)
    runner = Rigor::Analysis::Runner.new(configuration: configuration(dir), cache_store: nil,
                                         environment: shared_environment)
    reported(guarded_run(runner).diagnostics)
  end

  def media(superclass) = "class Media < #{superclass}\nend\n"

  def write_tree(dir, superclass)
    File.write(File.join(dir, "base.rb"), "class Base\n  def fail_with(message) = raise(ArgumentError, message)\n" \
                                          "end\nmodule Raiser\n  def fail_with(message) = raise(message)\nend\n")
    File.write(File.join(dir, "a.rb"), media(superclass))
    File.write(File.join(dir, "b.rb"), <<~RUBY)
      class Media
        include Raiser if ENV["RIGOR_X"]
        def lookup(list)
          count = [7, 10].find { |n| n <= list.length }
          fail_with "no" unless count
          list[-count..]
        end
      end
    RUBY
    Rigor::Analysis::IncrementalSession.new(configuration: configuration(dir), paths: [dir],
                                            environment: shared_environment)
  end

  let(:fired) { [["b.rb", 6, "call.possible-nil-receiver"]] }

  it "re-checks the caller when the superclass expression becomes a constant" do
    Dir.mktmpdir do |dir|
      session = write_tree(dir, "Class.new(Base)")
      expect(reported(guarded_baseline(session))).to eq(fired)

      File.write(File.join(dir, "a.rb"), media("Base"))
      warm = reported(guarded_recheck(session).diagnostics)
      expect(full_run(dir)).to eq([])
      expect(warm).to eq([])
    end
  end

  it "re-checks the caller when the constant superclass becomes an expression" do
    Dir.mktmpdir do |dir|
      session = write_tree(dir, "Base")
      expect(reported(guarded_baseline(session))).to eq([])

      File.write(File.join(dir, "a.rb"), media("Class.new(Base)"))
      warm = reported(guarded_recheck(session).diagnostics)
      expect(full_run(dir)).to eq(fired)
      expect(warm).to eq(fired)
    end
  end
end
