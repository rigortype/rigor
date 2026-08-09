# frozen_string_literal: true

require "spec_helper"

# #320 — the private-singleton-object idiom: a constant holds a plain object whose singleton class carries the
# methods (`class << Merger = Object.new`, as in haml's `AttributeMerger`). The constant read types as `Object`, so
# before this the singleton body was invisible and every call into it fired `call.undefined-method` on working code.
# The body's methods are keyed on the constant's own name, so the recovery is scoped to that name: an undefined
# method on the same constant, and any method on a sibling constant with no singleton body, still fire.
RSpec.describe "singleton-object constant dispatch" do
  def undefined_method_messages(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
                           .select { |d| d.rule == "call.undefined-method" }
                           .map(&:message)
  end

  # The type of the program's last top-level statement (the call under test in every example below).
  def last_statement_type(source)
    program = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    node = program.statements.body.last
    index[node].type_of(node)
  end

  it "stays silent on a method defined in a `class << Const = Object.new` body" do
    source = <<~RUBY
      class << Merger = Object.new
        def merge_attributes!(a, b) = a
      end
      Merger.merge_attributes!({}, {})
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "stays silent on a `class << Const` body opened on a separate assignment" do
    source = <<~RUBY
      Plain = Object.new
      class << Plain
        def plain_call(x) = x
      end
      Plain.plain_call(1)
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "stays silent for the `::Const` root-qualified spelling" do
    source = <<~RUBY
      class << ::Rooted = Object.new
        def rooted_call = 1
      end
      ::Rooted.rooted_call
    RUBY

    expect(undefined_method_messages(source)).to be_empty
  end

  it "still fires for a name the singleton body does not define" do
    source = <<~RUBY
      class << Merger = Object.new
        def merge_attributes!(a, b) = a
      end
      Merger.nope
    RUBY

    expect(undefined_method_messages(source)).to contain_exactly(
      a_string_matching(/undefined method `nope' for Object/)
    )
  end

  it "still fires on a sibling `Object.new` constant with no singleton body" do
    source = <<~RUBY
      class << Merger = Object.new
        def merge_attributes!(a, b) = a
      end
      Other = Object.new
      Other.nope
    RUBY

    expect(undefined_method_messages(source)).to contain_exactly(
      a_string_matching(/undefined method `nope' for Object/)
    )
  end

  it "types the call as the singleton method's inferred return, not merely stopping the error" do
    source = <<~RUBY
      class << Merger = Object.new
        def merge_attributes!(a, b) = a
      end
      Merger.merge_attributes!(1, 2)
    RUBY

    expect(last_statement_type(source).describe(:short)).to eq("1")
  end
end
