# frozen_string_literal: true

require "rbs"

require_relative "../rbs_extended"
require_relative "reporter"

module Rigor
  module RbsExtended
    # Collects every effect envelope the project's own RBS declares (ADR-103 WD5 / WD14; #383).
    #
    # It produces values, never diagnostics — the check that compares a bound against the proven
    # summaries is {Rigor::Effects::EnvelopeCheck}. Two tables come out, because they are consumed
    # differently:
    #
    # - {Result#method_envelopes} — keyed by method key (`Class#m` / `Class.m`), applied as written.
    # - {Result#class_envelopes} — keyed by class / module name, DISTRIBUTED by the check to every
    #   method of that Ruby class discovery knows (reopenings, other files, synthesized `attr_*` and
    #   `define_method` members), never to subclasses. A per-method envelope wins over a distributed
    #   one; nearest wins, and no `-except` syntax is needed.
    #
    # ## Why it parses rather than reading the built environment
    #
    # {ConformanceChecker}, the obvious model, walks `RbsLoader`'s built env. An envelope cannot: the
    # diagnostic has to name **where the bound was written** (`sig/foo.rbs:12`), and the ADR-54 env
    # cache dumps every `RBS::Location` to a zero-range `<cached>` sentinel, so a warm run would lose
    # both the position and the only evidence of which file a declaration came from. Parsing the
    # project's own signature sources is a few milliseconds over a tree Rigor already globs, it is
    # identical warm and cold, and it enforces ADR-103 WD6's trust rule structurally: a `%a{pure}` in
    # rbs core or in a gem's shipped RBS is never read, so it cannot bound a project method that
    # happens to share its key.
    #
    # Malformed payloads and `pure`-versus-`effect` contradictions are recorded on a {Reporter} the
    # scanner owns and ride out on {Result#unresolved}. They surface no diagnostic in this slice:
    # `effect.unknown-label` and the annotation-in-a-project-without-`effects:` residual are #384's.
    module EnvelopeScanner
      Result = Data.define(:method_envelopes, :class_envelopes, :unresolved) do
        def empty? = method_envelopes.empty? && class_envelopes.empty?
      end

      EMPTY = Result.new(method_envelopes: {}.freeze, class_envelopes: {}.freeze, unresolved: [].freeze)

      # RBS's kind for a `def self?.x` member — it declares BOTH sides, so the envelope binds both.
      SINGLETON_INSTANCE = :singleton_instance
      private_constant :SINGLETON_INSTANCE

      module_function

      # @param sources [Array<Array(String, String)>] `[buffer name, RBS source]` pairs — the project's
      #   `.rbs` files, plus the virtual entries rbs-inline and plugin `source_rbs` synthesis contribute.
      # @param registry [Rigor::Effects::Registry] the vocabulary an unknown label is judged against.
      # @return [Result]
      def scan(sources:, registry:)
        reporter = Reporter.new
        methods = {}
        classes = {}
        sources.each do |name, content|
          declarations(name, content).each do |decl|
            walk(decl, [], methods, classes, registry, reporter)
          end
        end
        Result.new(
          method_envelopes: methods.freeze, class_envelopes: classes.freeze,
          unresolved: reporter.unresolved_payloads
        )
      rescue StandardError
        EMPTY
      end

      # The **accepted-signature** reader: every per-method envelope declared anywhere in a BUILT
      # `RBS::Environment` — a gem's shipped signatures, Rigor's bundled overlays, core RBS
      # (ADR-103 WD6; #386).
      #
      # It exists for one purpose and is usable for exactly one: importing a `≤` bound at a call site
      # that resolves into un-analysed code ({Rigor::Effects::EnvelopeIndex}). It MUST NOT feed a
      # contract check. Two facts make that a structural guarantee rather than a convention —
      # {.scan}, which the check reads, never opens this door, and the values here carry no
      # `location` at all (the ADR-54 env cache dumps every `RBS::Location` to a `<cached>` sentinel,
      # so a warm run could not name where the bound was written even if a diagnostic wanted to).
      # There is also no body to check: a gem method is un-analysed by definition, which is why WD6
      # trusts the declaration instead, exactly as it already trusts the gem's *types*.
      #
      # Class-level annotations are deliberately not read. Distribution needs "every method of the
      # class discovery knows", which is a project fact; a gem's class-level tag would have to
      # distribute over a definition set this reader does not have.
      #
      # @param loader [Rigor::Environment::RbsLoader] the run's loader; it owns the env walk
      #   ({Rigor::Environment::RbsLoader#each_annotated_method_member}), so the environment itself never
      #   leaves it.
      # @param registry [Rigor::Effects::Registry]
      # @return [Hash{String => Rigor::Effects::Envelope}] keyed `Class#m` / `Class.m`
      def from_loader(loader:, registry:)
        out = {}
        loader.each_annotated_method_member do |class_name, member|
          keys_for(class_name, member).each do |key|
            next if out.key?(key)

            envelope = RbsExtended.read_effect_envelope(
              member.annotations, owner_key: key, source: :effect_annotation, registry: registry
            )
            out[key] = envelope if envelope
          end
        end
        out.freeze
      rescue StandardError
        {}.freeze
      end

      # Fail-soft per file: an unparseable `.rbs` is already quarantined by the loader and reported as
      # `rbs.coverage.quarantined-signature`; contributing no envelope is the consistent answer here.
      def declarations(name, content)
        _, _, decls = ::RBS::Parser.parse_signature(::RBS::Buffer.new(name: name, content: content))
        decls || []
      rescue StandardError
        []
      end

      # Descends the declaration tree, carrying the lexical prefix so a nested `class Bar` inside
      # `module Foo` keys as `Foo::Bar` — the same spelling the effects scanner gives its units.
      def walk(decl, prefix, methods, classes, registry, reporter)
        return unless decl.is_a?(::RBS::AST::Declarations::Class) || decl.is_a?(::RBS::AST::Declarations::Module)

        nested = prefix + [decl.name.to_s.sub(/\A::/, "")]
        class_name = nested.join("::")
        envelope = RbsExtended.read_effect_envelope(
          decl.annotations, owner_key: class_name, source: :class_annotation,
                            registry: registry, reporter: reporter
        )
        classes[class_name] = envelope if envelope
        decl.members.each { |member| absorb_member(member, nested, methods, classes, registry, reporter) }
      end

      def absorb_member(member, prefix, methods, classes, registry, reporter)
        return walk(member, prefix, methods, classes, registry, reporter) unless
          member.is_a?(::RBS::AST::Members::MethodDefinition)
        return if member.annotations.nil? || member.annotations.empty?

        keys_for(prefix.join("::"), member).each do |key|
          envelope = RbsExtended.read_effect_envelope(
            member.annotations, owner_key: key, source: :effect_annotation,
                                registry: registry, reporter: reporter
          )
          methods[key] = envelope if envelope
        end
      end

      # The effect-unit keys one RBS member declares. `def self?.x` declares both sides, so its
      # envelope binds both; every other kind declares one.
      def keys_for(class_name, member)
        case member.kind
        when :singleton then ["#{class_name}.#{member.name}"]
        when SINGLETON_INSTANCE then ["#{class_name}##{member.name}", "#{class_name}.#{member.name}"]
        else ["#{class_name}##{member.name}"]
        end
      end

      private_class_method :declarations, :walk, :absorb_member, :keys_for
    end
  end
end
