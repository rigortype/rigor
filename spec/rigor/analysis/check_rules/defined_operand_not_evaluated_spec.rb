# frozen_string_literal: true

require "spec_helper"

# Issue #318 — `defined?` never evaluates its operand: the runtime inspects the expression statically and
# returns a description string (or nil), it never runs it. Rigor's engine-owned tree walks
# (`Rigor::Analysis::CheckRules::RuleWalk`, `Rigor::Plugin::NodeRuleWalk`, and the shared
# `Rigor::Source::NodeWalker` they and `StatementEvaluator`'s internal scans build on) previously descended
# into a `Prism::DefinedNode`'s `#value` exactly like any other reachable expression, so a receiver-typing
# diagnostic (`call.undefined-method`) fired against code that can never execute.
#
# Ruby's `defined?` keyword (no explicit call-parens hugging the keyword) has LOWER precedence than `&&`,
# so `defined? @x && @x.m` parses as `defined?(@x && @x.m)` — the ENTIRE `&&` expression, including the
# `.m` call, is the operand. That is the shape this spec guards (and the real net-ssh
# `test/authentication/methods/test_keyboard_interactive.rb:14` instance the issue cites). It is NOT the
# same as `defined?(@x) && @x.m` (explicit parens around just `@x`): there `.m` sits OUTSIDE the `defined?`
# call as the right side of a real `&&`, so it is genuine evaluated code and a nil receiver there is a
# true positive — untouched by this fix (see the "still fires" example below).
RSpec.describe "defined? operand is not evaluated" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def undefined_method_messages(source)
    diagnostics_for(source).select { |d| d.rule == "call.undefined-method" }.map(&:message)
  end

  it "stays silent for a call inside defined?'s low-precedence operand (the issue's net-ssh shape)" do
    source = <<~RUBY
      class C
        def setup
          reset if defined? @subject && !@subject.options.empty?
        end

        def reset
          @subject = nil
        end
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "still fires for the identical call written outside defined? (control)" do
    source = <<~RUBY
      class C
        def setup
          @subject.options
        end

        def reset
          @subject = nil
        end
      end
    RUBY

    expect(undefined_method_messages(source)).to include(/undefined method `options' for nil/)
  end

  it "still fires for a genuinely undefined method elsewhere in a file that also guards with defined?" do
    source = <<~RUBY
      class C
        def setup
          reset if defined? @subject && !@subject.options.empty?
        end

        def reset
          @subject = nil
        end

        def other
          5.genuinely_undefined_method_xyz
        end
      end
    RUBY

    expect(undefined_method_messages(source)).to include(/undefined method `genuinely_undefined_method_xyz' for 5/)
  end

  it "stays silent for defined?(some_undefined_method) — the method is never dispatched" do
    source = <<~RUBY
      class C
        def check
          defined?(some_undefined_method)
        end
      end
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "still fires when a call inside defined?(...) && real_code has the parenthesized shape (true positive)" do
    # `defined?(@subject)` — explicit parens close right after `@subject` — leaves `!@subject.options.empty?`
    # OUTSIDE the defined? call, as the real right operand of `&&`. `defined?` proves definedness, not
    # non-nilness (@subject really is nil-typed here, from `reset`), so this genuinely raises at runtime if
    # reached. Suppressing it would be the unsound narrowing the issue explicitly warns against inventing.
    source = <<~RUBY
      class C
        def setup
          reset if defined?(@subject) && !@subject.options.empty?
        end

        def reset
          @subject = nil
        end
      end
    RUBY

    expect(undefined_method_messages(source)).to include(/undefined method `options' for nil/)
  end

  it "types defined?(...) itself as String | nil regardless of the operand" do
    source = <<~RUBY
      class C
        def check
          defined?(@subject)
        end
      end
    RUBY

    expect(diagnostics_for(source).select { |d| d.path == "mem.rb" }).to be_empty
  end
end
