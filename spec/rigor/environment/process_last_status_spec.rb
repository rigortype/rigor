# frozen_string_literal: true

# `Process.last_status` resolves, and reads what `$?` reads.
#
# CRuby defines `Process.last_status` as a singleton method answering the thread's last child status, the slot `$?`
# reads (`rb_last_status_get` in `process.c`). No ruby/rbs release declares it, so
# `system("true"); status = Process.last_status` reported `call.undefined-method` on correct code.
# `data/core_overlay/process.rbs` declares `() -> Process::Status?`, and `MethodDispatcher::ProcessFolding` answers a
# bound `$?`, so `status.exitstatus` past `system` does not trade the undefined method for a possible nil receiver.
#
# This file lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)" job runs.
require "spec_helper"

RSpec.describe "Process.last_status" do
  describe "the RBS definition" do
    let(:loader) { Rigor::Environment::RbsLoader.new(libraries: []) }

    def process_singleton_methods
      loader.singleton_definition("Process")&.methods
    end

    it "declares () -> Process::Status? from the core overlay" do
      method = process_singleton_methods&.[](:last_status)

      expect(method).not_to be_nil
      expect(method.method_types.map(&:to_s)).to eq(["() -> ::Process::Status?"])
      expect(method.defs.map { |definition| definition.member.location.buffer.name.to_s })
        .to all(end_with("data/core_overlay/process.rbs"))
    end

    it "leaves Process's upstream singleton methods buildable" do
      expect(process_singleton_methods&.keys).to include(:pid, :wait, :clock_gettime, :last_status)
    end
  end

  describe "inference", type: :runner do
    def dumped_types(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      result.diagnostics.filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end
    end

    def error_lines(source)
      analyze(source).diagnostics.select { |diagnostic| diagnostic.severity == :error }.map do |diagnostic|
        [diagnostic.line, diagnostic.qualified_rule]
      end
    end

    # THE REPORTED FALSE POSITIVE, and its use. The last two lines are the positive control: a Process method that
    # does not exist, and a wrong arity on this one, still report, so the silence above is not `Process` degraded to
    # `Dynamic[top]`.
    it "resolves Process.last_status and still reports what Process does not answer" do
      expect(error_lines(<<~RUBY)).to eq([[6, "call.undefined-method"], [7, "call.wrong-arity"]])
        def c
          system("true")
          status = Process.last_status
          status.exitstatus
        end
        Process.last_statuz
        Process.last_status(1)
      RUBY
    end

    # Where `$?` is unbound the method reads its declaration, as `Regexp.last_match` does with no match before it —
    # not the `Dynamic[top]` an unbound `$?` reads until declared globals are (#1366).
    it "answers Process::Status | nil where no subprocess is known to have run" do
      expect(dumped_types(<<~RUBY)).to eq(["Process::Status?", "Process::Status?", "Process::Status?"])
        def fresh
          dump_type(Process.last_status)
        end
        def maybe(flag)
          system("true") if flag
          dump_type(Process.last_status)
        end
        def rescued
          system("true")
        rescue StandardError
          dump_type(Process.last_status)
        end
      RUBY
    end

    it "answers what a bound $? answers" do
      expect(dumped_types(<<~RUBY)).to eq(%w[Process::Status Process::Status Process::Status Dynamic[top]])
        def ran
          `true`
          dump_type(Process.last_status)
          dump_type($?)
          system("true")
          dump_type(Process.last_status)
        end
        class Runner
          system("true")
          define_method(:later) { dump_type(Process.last_status) }
        end
      RUBY
    end

    # A project `Process.last_status` may answer anything, and the overlay's declaration would otherwise outrank it.
    # A `last_status` defined on another receiver is not that method, and does not turn the reading off.
    it "answers Dynamic[top] where the project defines Process.last_status itself" do
      spellings = [
        "module Process\n  def self.last_status = :mine\nend",
        "class << Process\n  def last_status = :mine\nend"
      ]
      redefined = spellings.map do |spelling|
        dumped_types("#{spelling}\nsystem(\"true\")\ndump_type(Process.last_status)")
      end
      unrelated = dumped_types(<<~RUBY)
        def last_status = :ok
        system("true")
        dump_type(Process.last_status)
      RUBY

      expect([redefined, unrelated]).to eq([[["Dynamic[top]"]] * 2, ["Process::Status"]])
    end

    it "answers Dynamic[top] where a pre_eval file patches Process.last_status" do
      result = analyze(
        files: {
          "app.rb" => <<~RUBY,
            require "rigor/testing"
            include Rigor::Testing
            system("true")
            dump_type(Process.last_status)
          RUBY
          "patch.rb" => "module Process\n  def self.last_status = :mine\nend\n"
        },
        config: { "paths" => %w[app.rb], "pre_eval" => %w[patch.rb] }
      )
      types = result.diagnostics.filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end

      expect(types).to eq(["Dynamic[top]"])
    end

    # A project `sig/` written for Steep, which reads the same rbs gap, may already declare the method. Its direct
    # `def` overrides the overlay's extended one instead of raising `DuplicatedMethodDefinitionError`, which would
    # leave every `Process` singleton method `Dynamic[top]` and the typo on the last line unreported.
    it "lets a project signature of Process.last_status stand without degrading Process" do
      steep_sig = "module Process\n  def self.last_status: () -> Integer\nend\n"
      result = analyze(<<~RUBY, sig: { "process.rbs" => steep_sig })
        require "rigor/testing"
        include Rigor::Testing
        dump_type(Process.last_status)
        dump_type(Process.pid)
        Process.last_statuz
      RUBY
      summary = result.diagnostics.filter_map do |diagnostic|
        if diagnostic.message.start_with?("dump_type")
          diagnostic.message.delete_prefix("dump_type: ")
        elsif diagnostic.severity != :info && diagnostic.qualified_rule != "call.unresolved-toplevel"
          diagnostic.qualified_rule
        end
      end

      expect(summary).to eq(%w[Integer Integer call.undefined-method])
    end

    # The paired control: the declared nil still reaches a local copy where no subprocess ran in the method, as
    # `m = Regexp.last_match; m[1]` does with no match before it.
    it "still reports a nil receiver where no subprocess is known to have run" do
      expect(error_lines(<<~RUBY)).to eq([[3, "call.possible-nil-receiver"]])
        def fresh
          status = Process.last_status
          status.exitstatus
        end
      RUBY
    end
  end
end
