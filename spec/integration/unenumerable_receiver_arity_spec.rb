# frozen_string_literal: true

# Issue #879 — `call.wrong-arity` read a receiver surface `call.undefined-method` had already declined to
# enumerate (#739 / #742). On one `Digest::Instance`-typed value, in one run, the analyzer refused to say
# which methods exist and asserted how many arguments one of them takes. A mixin-module type means "an
# instance of some class that includes this module", and that class may declare the name with a wider
# arity, so the arity verdict is a false positive on correct code.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "call.wrong-arity on an unenumerable receiver (#879)" do
  def write_project(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "arity.rb"), source)
  end

  def rules_and_messages
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.map { |d| [d.qualified_rule, d.message] }
  end

  around do |example|
    Dir.mktmpdir("rigor-unenumerable-arity-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "declines arity on a mixin-module receiver, declines its undefined method, and keeps the control" do
    # The control arm is not optional: `String` is a real class with an enumerable surface, and without it
    # a stand-down written over every receiver — or a formatter that ate the arguments — would pass here.
    write_project(<<~RUBY)
      require "digest"

      def unenumerable_module_receiver(v)
        return unless v.is_a?(Digest::Instance)

        v.hexdigest(1, 2, 3)
      end

      def unenumerable_module_receiver_undefined(v)
        return unless v.is_a?(Digest::Instance)

        v.no_such_method_zzz
      end

      def enumerable_control(v)
        return unless v.is_a?(String)

        v.upcase(1, 2, 3)
      end
    RUBY

    reported = rules_and_messages
    expect(reported).to eq(
      [["call.wrong-arity",
        "wrong number of arguments to `upcase' on String (given 3, expected 0..2)"]]
    )
  end
end
