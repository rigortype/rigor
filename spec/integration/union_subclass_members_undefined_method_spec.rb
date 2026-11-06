# frozen_string_literal: true

# Issue #2939 — a union keeps a nominal subclass member beside its superclass, so a caller reads the union
# member by member and does not report a method only the narrower arm lacks.
#
# `err(false)` returns `SystemCallError`, which has `#errno`; `StandardError` does not. The union return
# `(StandardError | SystemCallError)` is therefore silent: `call.undefined-method` fires on a union only when
# every non-nil arm lacks the method. The same signature collapsed to `StandardError` would report `errno`
# as undefined, which is a false positive on correct code (Ruby prints 2). The two examples are a pair:
# the first pins the kept union, the second pins that the superclass alone does report, so the first cannot
# pass by the analyzer going blind to `errno`. See docs/type-specification/normalization.md § "Member
# absorption" and ADR-14's 2026-11-07 working decision.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a union of a nominal subclass pair keeps the narrower arm (#2939)" do
  def write_project(return_type)
    FileUtils.mkdir_p("lib")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "e.rbs"), <<~RBS)
      class E
        def err: (untyped) -> #{return_type}
      end
    RBS
    File.write(File.join("lib", "e.rb"), <<~RUBY)
      class E
        def err(f) = f ? StandardError.new : SystemCallError.new("x", 2)
      end
    RUBY
    File.write(File.join("lib", "caller.rb"), <<~RUBY)
      def run = E.new.err(false).errno
    RUBY
  end

  def undefined_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "signature_paths" => %w[sig], "workers" => 0
      )
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-union-subclass-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "reports nothing for the kept union, since SystemCallError answers #errno" do
    write_project("(StandardError | SystemCallError)")

    expect(undefined_messages).to be_empty
  end

  it "reports the one undefined call when the return is the superclass alone (guard)" do
    write_project("StandardError")

    expect(undefined_messages).to contain_exactly(a_string_including("undefined method `errno' for StandardError"))
  end
end
