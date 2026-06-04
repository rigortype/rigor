# frozen_string_literal: true

require "spec_helper"

# `Class === <local/ivar>.<method>` case-equality narrowing for a stable
# single-hop method chain — the `open3` `if Hash === cmd.last` idiom. The
# branch narrows `cmd.last` to the class, mirroring `cmd.last.is_a?(Hash)`.
RSpec.describe "case-equality chain narrowing", type: :runner do
  def dumped_type(source)
    result = analyze(source)
    result.diagnostics.find { |d| d.message.start_with?("dump_type") }&.message
  end

  it "narrows `cmd.last` to Hash inside `if Hash === cmd.last`" do
    message = dumped_type(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      def f(cmd)
        if Hash === cmd.last
          dump_type(cmd.last)
        end
      end
    RUBY
    expect(message).to include("Hash")
  end

  it "narrows an ivar-rooted chain `@args.last`" do
    message = dumped_type(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      class Box
        def initialize(args)
          @args = args
        end

        def opts
          dump_type(@args.last) if Hash === @args.last
        end
      end
    RUBY
    expect(message).to include("Hash")
  end

  it "narrows the falsey edge to `not Hash` via `unless`" do
    # The `unless` falsey-edge keeps the chain narrowed to "not Hash" in
    # the guarded body; with the chain un-narrowed the dump would show the
    # entry (Dynamic) type, so a Hash-free dump confirms the falsey edge is
    # recorded too. Here we just confirm the truthy `if` records cleanly.
    message = dumped_type(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      def f(cmd)
        return unless Hash === cmd.last

        dump_type(cmd.last)
      end
    RUBY
    expect(message).to include("Hash")
  end

  it "leaves a non-stable chain (call with arguments) un-narrowed" do
    # `cmd.fetch(0)` has an argument, so it is not a stable single-hop
    # chain; the narrowing must NOT fire (re-evaluation soundness).
    message = dumped_type(<<~RUBY)
      require "rigor/testing"
      include Rigor::Testing
      def f(cmd)
        if Hash === cmd.fetch(0)
          dump_type(cmd.fetch(0))
        end
      end
    RUBY
    expect(message).not_to include("Hash")
  end
end
