# frozen_string_literal: true

require "spec_helper"

# Issue #1569 — `module_function` makes a module function's instance copy private, so a class that includes the
# module and overrides the method privately reduces nothing. Ruby 4.0.5's answer for each shape is in the comment.
RSpec.describe "def.override-visibility-reduced over a module_function's instance copy (#1569)", type: :runner do
  def reduced(source = nil, files: {})
    analyze(source, files: files).diagnostics.select { |d| d.rule == "def.override-visibility-reduced" }
                                 .map { |d| [File.basename(d.path), d.line] }
  end

  # Ruby: `Helpers.private_instance_methods(false)` is `[:fmt]`.
  it "is quiet on a private override of a bare module_function's def" do
    expect(reduced(<<~RUBY)).to eq([])
      module Helpers
        module_function

        def fmt(value) = value.to_s
      end

      class Report
        include Helpers

        private

        def fmt(value) = "r\#{value}"
      end
    RUBY
  end

  # A guard: the control without `module_function`. Ruby: `Helpers#fmt` is public, so the private override reduces it.
  it "still reports the private override of a public module method" do
    expect(reduced(<<~RUBY)).to eq([["code.rb", 9]])
      module Helpers
        def fmt(value) = value.to_s
      end

      class Report
        include Helpers

        private
        def fmt(value) = "r\#{value}"
      end
    RUBY
  end

  # Ruby: `Named#fmt` and `MfDef#fmt` are private; `PubDef#fmt` and `Reset#fmt` are public.
  it "reads the named forms as private, and `public def` or a bare `public` after the toggle as public" do
    expect(reduced(<<~RUBY)).to eq([["code.rb", 23], ["code.rb", 24]])
      module Named
        def fmt = 1
        module_function :fmt
      end

      module MfDef
        module_function def fmt = 1
      end

      module PubDef
        module_function
        public def fmt = 1
      end

      module Reset
        module_function
        public
        def fmt = 1
      end

      class A; include Named; private def fmt = 2; end
      class B; include MfDef; private def fmt = 2; end
      class C; include PubDef; private def fmt = 2; end
      class D; include Reset; protected def fmt = 2; end
    RUBY
  end

  # A guard: the slot after a reset that may not run was contested before #1569 too. Ruby: the `public` does not run
  # here, so `Maybe#fmt` is private, and the walk does not answer public.
  it "is quiet after a bare public that may not run" do
    expect(reduced(<<~RUBY)).to eq([])
      module Maybe
        module_function
        public if ENV["X"]
        def fmt = 1
      end

      class Report
        include Maybe
        private def fmt = 2
      end
    RUBY
  end

  it "reads the module_function across files" do
    files = {
      "helpers.rb" => "module Helpers\n  module_function\n  def fmt = 1\nend\n",
      "report.rb" => "class Report\n  include Helpers\n  private def fmt = 2\nend\n"
    }
    expect(reduced(files: files)).to eq([])
  end
end
