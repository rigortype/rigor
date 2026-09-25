# frozen_string_literal: true

module Rigor
  class Environment
    # ADR-112 WD5 / issue #1075 — the consistency rule for one member declared by two sources. It replaces
    # ADR-32 WD13's "`sig/` wins per member": a `sig/` declaration and an inline (`@rbs` / `#:`) one of the
    # same member are compared instead of ranked.
    #
    # - **Consistent** — in every type position one side's type is a subtype of the other's. `untyped` (and
    #   `void` / `top`, which RBS defines as the same top type) is consistent with everything and is the
    #   least precise answer, so a migrating project's `sig/ -> untyped` beside an inline `-> void` stays
    #   quiet (ADR-93's herb case). The two merge to the more precise side: when every position of the
    #   inline member is at least as precise as `sig/`'s and one is strictly more, the inline member binds
    #   and the `sig/` one stands down; otherwise `sig/` binds. Nothing is reported either way. The merge
    #   takes the narrower type in parameter positions too, which is the author's stated contract.
    # - **Contradiction** — proven: some position whose two types are disjoint (no value is both), positional
    #   arity ranges that cannot meet, or a keyword one side requires and the other cannot take in any form.
    #   `sig/` still binds, so the class builds, and the run reports `rbs.contradicting-signature` as an
    #   error.
    # - **Undecided** — everything else: a position Rigor cannot read faithfully, two types it cannot prove
    #   disjoint, shapes that differ without contradicting, overloads that do not pair one to one, or each
    #   side more precise in a different position. `sig/` binds and the dropped inline member is reported
    #   at `:info` under ADR-32 WD12, as every inline member was before.
    #
    # The false-positive discipline holds the DEFINITION of a contradiction (ADR-112 WD5): every doubt
    # lands in "undecided". {Comparator} carries the type work and says what counts as a proof.
    #
    # The same comparison answers `rbs-extended.md`'s "an annotation whose refinement exceeds the ordinary
    # RBS contract is a conflict": a member-level `rigor:v1:return:` / `rigor:v1:param:` payload disjoint
    # from the member's own declared type is reported under the same identifier.
    #
    # The comparison works on one member PAIR and knows nothing about where either side came from, so a
    # third source (ADR-112's `@extrbs`, #1073) plugs in as another caller of {Comparator#compare}.
    #
    # Pure over RBS AST members: no environment is consulted, so {RbsLoader} derives the same answer from its
    # inputs at build time and on an environment-cache HIT.
    module MemberConsistency
      # One outcome per `(class, method, kind)` key two sources declare, or per member whose refinement
      # exceeds its own declared type (`outcome: :refinement`). `signature_path` / `signature_line` locate
      # the `.rbs` member (nil for a refinement record read off an inline member); `virtual_name` is the
      # synthesized buffer name of the inline source (nil for a refinement record read off a `.rbs` member).
      Record = Data.define(:class_name, :method_name, :kind, :outcome, :detail, :signature_path,
                           :signature_line, :virtual_name)

      # What the environment build needs from the rule: which inline keys stand down, and which `.rbs`
      # members stand down per file (because the inline side was the more precise one).
      Resolution = Data.define(:records, :inline_standdowns, :signature_standdowns)

      EMPTY = Ractor.make_shareable(
        Resolution.new(records: [], inline_standdowns: Set.new, signature_standdowns: {})
      )

      # Outcomes that report, and how loud.
      ERROR_OUTCOMES = %i[contradiction refinement].freeze
      INFO_OUTCOMES = %i[undecided].freeze

      NO_RECORDS = [].freeze
      private_constant :NO_RECORDS

      class << self
        # @param signature_members — `{[class, method, kind] => [signature_path, member, visibility]}`, the
        #   first project `.rbs` member declaring each key, with its effective visibility.
        # @param inline_members — `[[virtual_name, class_name, member, visibility], ...]`, every member the
        #   inline sources declare.
        # @param shadowable — the first segment of every class / module name the project's inputs declare
        #   ({Comparator#initialize}).
        # @return a {Resolution}. Records are sorted and deduplicated; silent outcomes are recorded too, so a
        #   caller can see what merged where.
        def resolve(signature_members, inline_members, shadowable: Set.new)
          return EMPTY if inline_members.empty?

          # Loaded here rather than with the file: {RbsLoader} requires this module on every run, and only a
          # project with inline RBS ever compares anything.
          require_relative "member_consistency/comparator"

          state = { comparator: Comparator.new(shadowable), records: [], inline: Set.new,
                    signature: Hash.new { |hash, file| hash[file] = Set.new }, checked: {}.compare_by_identity }
          inline_members.each do |virtual_name, class_name, member, visibility|
            state[:records].concat(refinement_records(state, class_name, member, nil, virtual_name))
            resolve_member(state, signature_members, [virtual_name, class_name, member, visibility])
          end
          Resolution.new(
            records: state[:records].uniq.sort_by { |r| record_sort_key(r) }.freeze,
            inline_standdowns: state[:inline].freeze,
            signature_standdowns: state[:signature].transform_values(&:freeze).freeze
          )
        end

        # The `[method_name, kind]` pairs one RBS member contributes to a definition build, mirroring
        # `RBS::DefinitionBuilder::MethodBuilder#build_instance` / `#build_singleton` — which is what decides
        # whether two members collide. An attribute contributes its reader and / or writer name (`foo`,
        # `foo=`), an alias its new name, and `def self?.x` both sides. An `overloading?` member (`def x: ...
        # | ...`) contributes NOTHING: rbs files those under `overloads` rather than `originals`, so they are
        # designed to compose with an existing declaration and are never compared against it.
        def member_method_keys(member)
          case member
          when ::RBS::AST::Members::MethodDefinition then method_definition_keys(member)
          when ::RBS::AST::Members::AttrReader then [[member.name, member.kind]]
          when ::RBS::AST::Members::AttrWriter then [[:"#{member.name}=", member.kind]]
          when ::RBS::AST::Members::AttrAccessor then [[member.name, member.kind], [:"#{member.name}=", member.kind]]
          when ::RBS::AST::Members::Alias then [[member.new_name, member.kind]]
          else []
          end
        end

        private

        def resolve_member(state, signature_members, inline)
          _virtual_name, class_name, member, = inline
          overlapping = member_method_keys(member).filter_map do |method_name, kind|
            key = [class_name, method_name, kind]
            owner = signature_members[key]
            owner && [key, *owner]
          end
          return if overlapping.empty?

          verdicts = overlapping.map do |key, path, sig_member, sig_visibility|
            record_signature_refinements(state, class_name, sig_member, path)
            [key, path, sig_member, state[:comparator].compare(sig_member, member, key[1]), sig_visibility]
          end
          binds = inline_binds?(state[:comparator], verdicts, overlapping.map(&:first), inline)
          apply_verdicts(state, verdicts, binds, inline[0])
        end

        # Records each key's outcome and files the losing side: every `.rbs` member the inline one displaces
        # when it binds, or every shared inline key when `sig/` does.
        def apply_verdicts(state, verdicts, inline_binds, virtual_name)
          verdicts.each do |key, path, sig_member, verdict, _|
            if inline_binds
              state[:signature][path].merge(full_keys(key[0], sig_member))
              verdict = [:inline, nil]
            else
              state[:inline] << key
              verdict = reported_verdict(verdict)
            end
            state[:records] << record(key, verdict, path, sig_member, virtual_name)
          end
        end

        # The inline member binds only when every key it shares is at least as precise inline, one is
        # strictly more, and swapping loses nothing the `.rbs` member said:
        #
        # - each `.rbs` member it displaces declares no key the inline member does not also declare (an
        #   `attr_accessor` in `sig/` against an inline `def foo` would otherwise take `foo=` down with it);
        # - the two have the same effective visibility (a `private def` in `sig/` must not turn public);
        # - every annotation on the `.rbs` member other than a `rigor:v1:return:` / `rigor:v1:param:`
        #   refinement (which the comparison has already weighed) is also on the inline member, so a
        #   predicate, an assertion or an effect envelope written in `sig/` does not vanish (ADR-32 WD12).
        def inline_binds?(comparator, verdicts, shared_keys, inline)
          outcomes = verdicts.map { |verdict| verdict[3].first }
          return false unless outcomes.all? { |outcome| %i[equal inline].include?(outcome) }
          return false unless outcomes.include?(:inline)

          shared = shared_keys.to_set
          verdicts.all? do |_, _, sig_member, _, sig_visibility|
            full_keys(inline[1], sig_member).all? { |key| shared.include?(key) } &&
              sig_visibility == inline[3] &&
              annotations_kept?(comparator, sig_member, inline[2])
          end
        end

        def annotations_kept?(comparator, sig_member, inline_member)
          kept = comparator.member_annotation_strings(inline_member)
          comparator.member_annotation_strings(sig_member).all? do |string|
            comparator.refinement_directive?(string) || kept.include?(string)
          end
        end

        # A key where the inline side was more precise, but the member as a whole could not bind, lost
        # something the author wrote: that is WD12's "parsed and not honoured", so it reports as undecided.
        def reported_verdict(verdict)
          if verdict.first == :inline
            return [:undecided,
                    "the inline declaration is more precise here but could not replace the `.rbs` member " \
                    "without dropping what it declares"]
          end

          verdict
        end

        def full_keys(class_name, member)
          member_method_keys(member).map { |method_name, kind| [class_name, method_name, kind] }
        end

        # The `.rbs` line is read only for an outcome that reports it: asking an `RBS::Buffer` for a line
        # builds that buffer's whole line table, a cost a silent merge has no use for.
        def record(key, verdict, path, sig_member, virtual_name)
          line = ERROR_OUTCOMES.include?(verdict[0]) ? member_line(sig_member) : nil
          Record.new(
            class_name: key[0], method_name: key[1], kind: key[2], outcome: verdict[0], detail: verdict[1],
            signature_path: path, signature_line: line, virtual_name: virtual_name
          )
        end

        def record_signature_refinements(state, class_name, sig_member, path)
          return if state[:checked].key?(sig_member)

          state[:checked][sig_member] = true
          state[:records].concat(refinement_records(state, class_name, sig_member, path, nil))
        end

        # `path` is the `.rbs` file for a `sig/` member (whose line is then read) and nil for an inline one.
        def refinement_records(state, class_name, member, path, virtual_name)
          conflicts = state[:comparator].refinement_conflicts(member)
          return NO_RECORDS if conflicts.empty?

          method_name, kind = member_method_keys(member).first || [member_name(member), :instance]
          line = path && member_line(member)
          conflicts.map do |detail|
            Record.new(class_name: class_name, method_name: method_name, kind: kind, outcome: :refinement,
                       detail: detail, signature_path: path, signature_line: line, virtual_name: virtual_name)
          end
        end

        def member_name(member)
          member.respond_to?(:name) ? member.name : member.new_name
        end

        def member_line(member)
          location = member.respond_to?(:location) ? member.location : nil
          location.respond_to?(:start_line) ? location.start_line : nil
        end

        # `Symbol#name` and `nil.to_s` are frozen, so the key allocates nothing but itself.
        def record_sort_key(record)
          [record.class_name, record.method_name.name, record.kind.name, record.outcome.name,
           record.virtual_name.to_s, record.signature_path.to_s, record.detail.to_s]
        end

        def method_definition_keys(member)
          return [] if member.respond_to?(:overloading?) && member.overloading?

          case member.kind
          when :instance then [[member.name, :instance]]
          when :singleton then [[member.name, :singleton]]
          else [[member.name, :instance], [member.name, :singleton]] # `def self?.x` defines both sides
          end
        end
      end
    end
  end
end
