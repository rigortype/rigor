# frozen_string_literal: true

# Issue #1494 — a `=~` subject whose class the project declares in another file is classified through the
# cross-file discovery pre-pass: a String subclass keeps the match edge, so a copy of `$1` read past the guard is
# not reported, while a subclass that defines its own `=~` (which binds `$~` in that method's frame) still is, and so
# is a String once the project reopens `String` with a `=~`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a `=~` guard on a String subclass declared in another file (#1494)" do
  def config
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
  end

  around do |example|
    Dir.mktmpdir("rigor-regex-match-subject-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write_project
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "strings.rb"), <<~RUBY)
      class PlainStr < String
      end

      class OwnMatchStr < String
        def =~(_other) = [0, nil].sample
      end
    RUBY
    File.write(File.join("lib", "caller.rb"), <<~RUBY)
      def plain(raw)
        s = PlainStr.new(raw)
        return unless s =~ /(a)/

        key = $1
        key.upcase
      end

      def own(raw)
        s = OwnMatchStr.new(raw)
        return unless s =~ /(a)/

        key = $1
        key.upcase
      end
    RUBY
  end

  it "reports the nil receiver only for the subclass with its own `=~`" do
    write_project
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: config), %w[lib])
    reported = result.diagnostics
                     .select { |d| d.path.to_s.end_with?("caller.rb") }
                     .map { |d| "#{d.line} #{d.qualified_rule}" }
    expect(reported).to eq(["14 call.possible-nil-receiver"])
  end

  # A project that reopens `String` with a `=~` of its own makes every String receiver one whose match runs in
  # that method's frame, so the copy of `$1` past the guard is reported again.
  it "reports the nil receiver for a String whose class the project reopens with a `=~`" do
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "ext.rb"), <<~RUBY)
      class String
        def =~(_other) = [0, nil].sample
      end
    RUBY
    File.write(File.join("lib", "caller.rb"), <<~RUBY)
      def reopened(raw)
        s = String(raw)
        return unless s =~ /(a)/

        key = $1
        key.upcase
      end
    RUBY
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: config), %w[lib])
    reported = result.diagnostics
                     .select { |d| d.path.to_s.end_with?("caller.rb") }
                     .map { |d| "#{d.line} #{d.qualified_rule}" }
    expect(reported).to eq(["6 call.possible-nil-receiver"])
  end
end
