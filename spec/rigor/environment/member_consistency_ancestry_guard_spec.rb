# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "rigor/environment/member_consistency"

# PR #1428 review — `rbs.contradicting-signature` proves two core / stdlib classes disjoint from their RBS
# ancestry. Where rbs and Ruby disagree (rbs 4.2: `Tempfile < File`, Ruby: `Tempfile < Delegator`), that
# proof reports an error on correct code, so `RbsProof::UNRELIABLE_ANCESTRY` excludes every class of a
# known disagreement. This guard finds the disagreements afresh: for each class the proof may use — every
# core or stdlib class the default libraries' RBS declares, plus a few common stdlib libraries — that Ruby
# can load, it checks that every class Ruby lists among its ancestors, and RBS declares, is also an RBS
# ancestor. A disagreement outside the exclusion list fails, so an rbs or Ruby bump that introduces one
# fails CI instead of producing false errors. Only this direction can make the proof wrong: RBS naming an
# ancestor Ruby lacks only ever makes the proof say less.
#
# It runs in a subprocess because it requires every library it checks, and a class those requires define
# would change answers elsewhere in the suite (the subtype check resolves loaded classes).
RSpec.describe "MemberConsistency::RbsProof ancestry guard" do
  let(:script) do
    <<~'RUBY'
      require "rbs"
      require "json"
      libraries = ARGV
      libraries.each do |library|
        require library.tr("-", "/")
      rescue LoadError, StandardError
        nil
      end
      loader = RBS::EnvironmentLoader.new
      libraries.each { |library| loader.add(library: library) if loader.has_library?(library: library, version: nil) }
      env = RBS::Environment.from_loader(loader).resolve_type_names
      ancestor_builder = RBS::DefinitionBuilder.new(env: env).ancestor_builder
      # The proof's candidates are classes whose primary declaration is Ruby core or rbs's stdlib — the test
      # `RbsLoader#core_or_stdlib_class?` applies — not a gem's own signatures (`prism`, `rbs`).
      roots = [RBS::EnvironmentLoader::DEFAULT_CORE_ROOT, RBS::Repository::DEFAULT_STDLIB_ROOT].map { |root| "#{root}/" }
      core_or_stdlib = lambda do |entry|
        decl = entry.respond_to?(:primary_decl) ? entry.primary_decl : entry.primary.decl
        buffer = decl.location&.buffer&.name.to_s
        roots.any? { |root| buffer.start_with?(root) }
      end
      compared = 0
      mismatches = []
      env.class_decls.each do |type_name, entry|
        next unless entry.is_a?(RBS::Environment::ClassEntry) && core_or_stdlib.call(entry)

        name = type_name.to_s.delete_prefix("::")
        runtime = begin
          Object.const_get(name)
        rescue NameError, LoadError
          nil
        end
        next unless runtime.instance_of?(Class)

        rbs_ancestors = begin
          ancestor_builder.instance_ancestors(type_name).ancestors.map { |a| a.name.to_s.delete_prefix("::") }
        rescue RBS::BaseError
          next
        end
        compared += 1
        runtime.ancestors.each do |ancestor|
          next unless ancestor.instance_of?(Class) && ancestor != runtime && ancestor.name

          declared = env.class_decls[RBS::TypeName.parse("::#{ancestor.name}")]
          next unless declared.is_a?(RBS::Environment::ClassEntry)

          mismatches << [name, ancestor.name] unless rbs_ancestors.include?(ancestor.name)
        end
      end
      puts JSON.generate("compared" => compared, "mismatches" => mismatches.uniq.sort)
    RUBY
  end

  let(:libraries) do
    (Rigor::Environment::DEFAULT_LIBRARIES + %w[set weakref ostruct socket net-http zlib openssl]).uniq
  end

  it "finds no RBS / Ruby ancestry disagreement outside RbsProof::UNRELIABLE_ANCESTRY" do
    output, error, status = Open3.capture3(RbConfig.ruby, "-e", script, *libraries)
    expect(status).to be_success, error

    result = JSON.parse(output.lines.last)
    # Not vacuous: the default libraries alone declare several hundred loadable classes.
    expect(result.fetch("compared")).to be > 300

    excluded = Rigor::Environment::MemberConsistency::RbsProof::UNRELIABLE_ANCESTRY
    unexcluded = result.fetch("mismatches").reject { |pair| pair.any? { |name| excluded.include?(name) } }
    expect(unexcluded).to be_empty,
                          "RBS and Ruby disagree about these ancestries (class, Ruby ancestor RBS omits): " \
                          "#{unexcluded.inspect}. Add the classes to RbsProof::UNRELIABLE_ANCESTRY, or " \
                          "`rbs.contradicting-signature` reports them as disjoint on correct code."
  end
end
