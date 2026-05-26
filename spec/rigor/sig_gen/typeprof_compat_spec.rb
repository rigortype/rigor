# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "rbs"

# TypeProf compatibility tests for Rigor::SigGen::Generator.
#
# Each fixture pairs a Ruby source with the RBS TypeProf would emit for it.
# The assertion is: Rigor covers at least as many methods and returns a type
# at least as specific for every shared method.
#
# TypeProf uses nominal class names (String, Integer) for literal returns;
# Rigor emits RBS literal types ("hello", 42). A literal is considered more
# specific than its base class, so the ordering is preserved.
#
# TypeProf is not invoked at test time — its output is hardcoded based on the
# upstream scenario corpus (test/typeprof/core/class/) and confirmed against
# TypeProf 2.x behaviour. If TypeProf changes its output format, update the
# fixture strings.
RSpec.describe "Rigor::SigGen::Generator TypeProf compatibility" do
  # ── fixture data ─────────────────────────────────────────────────────────────

  TYPEPROF_COMPAT_FIXTURES = [
    {
      description: "literal-returning instance methods",
      ruby_source: <<~RUBY,
        class Literals
          def greet; "hello"; end
          def count; 42; end
          def rate; 1.5; end
          def nothing; nil; end
          def tag; :done; end
        end
      RUBY
      # TypeProf infers nominal types for String / Integer / Float literals;
      # it does preserve Symbol and nil literal types.
      typeprof_rbs: <<~RBS
        class Literals
          def greet: () -> String
          def count: () -> Integer
          def rate: () -> Float
          def nothing: () -> nil
          def tag: () -> :done
        end
      RBS
    },
    {
      description: "singleton and instance methods on the same class",
      ruby_source: <<~RUBY,
        class Counter
          def self.initial; 0; end
          def self.label; "counter"; end
          def value; 1; end
        end
      RUBY
      typeprof_rbs: <<~RBS
        class Counter
          def self.initial: () -> Integer
          def self.label: () -> String
          def value: () -> Integer
        end
      RBS
    },
    {
      description: "mixed return kinds in a single class",
      ruby_source: <<~RUBY,
        class Status
          def code; 200; end
          def message; "ok"; end
          def kind; :success; end
          def missing; nil; end
        end
      RUBY
      typeprof_rbs: <<~RBS
        class Status
          def code: () -> Integer
          def message: () -> String
          def kind: () -> :success
          def missing: () -> nil
        end
      RBS
    },
    {
      description: "nested module and class",
      ruby_source: <<~RUBY,
        module Api
          class Response
            def status; 201; end
            def body; "created"; end
          end
        end
      RUBY
      typeprof_rbs: <<~RBS
        module Api
          class Response
            def status: () -> Integer
            def body: () -> String
          end
        end
      RBS
    }
  ].freeze

  # ── helpers ──────────────────────────────────────────────────────────────────

  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def make_generator(paths:)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => paths).compact
    )
    Rigor::SigGen::Generator.new(configuration: configuration, paths: paths)
  end

  # Run Rigor sig-gen on a Ruby source string.
  # Returns a Hash keyed by [kind, method_name] → Candidate.
  def run_rigor(ruby_source)
    path = write_fixture("lib/subject.rb", ruby_source)
    make_generator(paths: [path])
      .run
      .select { |c| c.classification == Rigor::SigGen::Classification::NEW_METHOD }
      .to_h { |c| [[c.kind, c.method_name], c] }
  end

  # Extract the return type string from a Rigor candidate's `.rbs` line by
  # wrapping it in a dummy class and parsing with RBS::Parser.
  # Returns the canonical `.to_s` form (e.g. "42", '"hello"', "Integer").
  def rigor_return_type(candidate)
    buf = RBS::Buffer.new(name: "rigor.rbs", content: "class X\n  #{candidate.rbs}\nend\n")
    _, _, decls = RBS::Parser.parse_signature(buf)
    decls.first.members.first.overloads.first.method_type.type.return_type.to_s
  end

  # Parse a TypeProf-style RBS string into a Hash keyed by [kind, method_name]
  # → return_type_string. Recurses into nested class / module declarations.
  def parse_typeprof_methods(rbs_source)
    buf = RBS::Buffer.new(name: "typeprof.rbs", content: rbs_source)
    _, _, decls = RBS::Parser.parse_signature(buf)
    result = {}
    collect_rbs_decls(decls, result)
    result
  end

  def collect_rbs_decls(decls, result)
    decls.each do |decl|
      next unless decl.is_a?(RBS::AST::Declarations::Class) ||
                  decl.is_a?(RBS::AST::Declarations::Module)

      collect_rbs_members(decl.members, result)
    end
  end

  def collect_rbs_members(members, result)
    members.each do |m|
      case m
      when RBS::AST::Members::MethodDefinition
        key = [m.kind, m.name]
        result[key] = m.overloads.first.method_type.type.return_type.to_s
      when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
        collect_rbs_members(m.members, result)
      end
    end
  end

  # Rigor emits RBS literal types (42, "hello") where TypeProf emits nominal
  # class names (Integer, String). A Rigor literal is considered at least as
  # specific as the corresponding base class.
  LITERAL_TO_BASE = {
    /\A-?\d+\z/ => "Integer", # integer literals: 0, 42, 200, 201
    /\A"/ => "String",    # string literals:  "hello", "ok"
    /\A:/ => "Symbol"     # symbol literals:  :done, :success
  }.freeze

  def at_least_as_specific?(rigor_return, typeprof_return)
    return true if typeprof_return == "untyped"
    return false if rigor_return == "untyped"
    return true if rigor_return == typeprof_return

    LITERAL_TO_BASE.any? { |pattern, base| rigor_return.match?(pattern) && typeprof_return == base }
  end

  # ── examples ─────────────────────────────────────────────────────────────────

  TYPEPROF_COMPAT_FIXTURES.each do |fixture|
    context fixture[:description] do
      let(:typeprof_methods) { parse_typeprof_methods(fixture[:typeprof_rbs]) }
      let(:rigor_candidates) { run_rigor(fixture[:ruby_source]) }

      it "covers every method TypeProf recognises" do
        missing = typeprof_methods.keys.reject { |key| rigor_candidates.key?(key) }
        expect(missing).to be_empty,
                           "Rigor missed methods that TypeProf covers: #{missing.map { |(k, n)| "#{k} #{n}" }.inspect}"
      end

      it "returns a type at least as specific as TypeProf for every shared method" do
        failures = typeprof_methods.filter_map do |(kind, name), tp_return|
          candidate = rigor_candidates[[kind, name]]
          next unless candidate

          rigor_ret = rigor_return_type(candidate)
          next if at_least_as_specific?(rigor_ret, tp_return)

          "#{kind} ##{name}: Rigor=#{rigor_ret.inspect} vs TypeProf=#{tp_return.inspect}"
        end

        expect(failures).to be_empty, "Type specificity regressions:\n#{failures.join("\n")}"
      end

      it "covers at least as many methods as TypeProf" do
        expect(rigor_candidates.size).to be >= typeprof_methods.size
      end
    end
  end
end
