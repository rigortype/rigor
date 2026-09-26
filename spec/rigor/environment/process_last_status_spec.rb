# frozen_string_literal: true

# `Process.last_status` resolves, and reads what `$?` reads.
#
# CRuby defines `Process.last_status` as a singleton method answering the thread's last child status, the slot `$?`
# reads (`rb_last_status_get` in `process.c`). No ruby/rbs release declares it, so
# `system("true"); status = Process.last_status` reported `call.undefined-method` on correct code.
# `data/core_overlay/process.rbs` declares `() -> Process::Status?`, and `MethodDispatcher::ProcessFolding` answers the
# non-nil `$?` binding a subprocess call leaves, so `status.exitstatus` past `system` does not trade the undefined
# method for a possible nil receiver.
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

    # A second `def self.last_status` from any source is a `DuplicatedMethodDefinitionError`, which leaves `Process`
    # known with no singleton surface at all.
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

    it "answers what $? answers past a subprocess" do
      expect(dumped_types(<<~RUBY)).to eq(["Process::Status", "Process::Status", "Process::Status"])
        def ran
          `true`
          dump_type(Process.last_status)
          dump_type($?)
          system("true")
          dump_type(Process.last_status)
        end
      RUBY
    end

    # A project `Process.last_status` may answer anything, so the binding is not read there. A `last_status` defined
    # on another receiver is not that method, and does not turn the reading off.
    it "reads the binding unless the project defines Process.last_status itself" do
      redefined = dumped_types(<<~RUBY)
        module Process
          def self.last_status = super
        end
        system("true")
        dump_type(Process.last_status)
      RUBY
      unrelated = dumped_types(<<~RUBY)
        def last_status = :ok
        system("true")
        dump_type(Process.last_status)
      RUBY

      expect([redefined, unrelated]).to eq([["Process::Status?"], ["Process::Status"]])
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
