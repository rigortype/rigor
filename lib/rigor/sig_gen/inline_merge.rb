# frozen_string_literal: true

require "rbs"

module Rigor
  module SigGen
    # ADR-112 WD4 — lays an inline declaration's AUTHORED parts over the `sig/` copy of the same method, slot by
    # slot, so that only what the author wrote can make the copy stale (#1076).
    #
    # rbs-inline fills every type slot the author left unannotated: a parameter or a keyword with `untyped`, a
    # `&block` with `?{ (?) -> untyped }`, a return with `untyped` (the synthesizer marks only the last one,
    # `rigor:v1:inferred-return`). None of those is a statement about the method, so none of them may overwrite
    # what `sig/` says there — a reviewer may have written `Integer b` or a typed block by hand. An `untyped`
    # the author did write (`#: (untyped) -> void`) cannot be told apart from a default and is kept at the
    # `sig/` side's type too; it says nothing either way.
    #
    # The merge answers `nil` when the two do not correspond slot for slot — a different overload count, or an
    # overload whose parameter lists differ in shape. Nothing sound can be written then: dropping a `sig/`
    # overload the inline declaration does not mention breaks correct callers of it, and a return inferred under
    # parameters that are about to change describes a method that does not exist yet.
    module InlineMerge
      module_function

      # @param authored — the inline declaration's overloads (names as written).
      # @param written — the `sig/` member's overloads, parsed from its own text (names as written).
      # @param return_defaulted — the inline returns are rbs-inline's `untyped` default, not the author's.
      # @return the merged overloads, or nil when the shapes do not correspond.
      def merge(authored, written, return_defaulted:)
        return nil unless authored.size == written.size

        merged = authored.zip(written).map { |a, w| merge_overload(a, w, return_defaulted) }
        merged.all? ? merged : nil
      end

      def merge_overload(authored, written, return_defaulted)
        type = merge_function(authored.type, written.type)
        return nil if type.nil?

        return_type = keep_written_return?(authored, return_defaulted) ? written.type.return_type : type.return_type
        authored.update(
          type_params: authored.type_params.empty? ? written.type_params : authored.type_params,
          type: type.with_return_type(return_type),
          block: authored_block?(authored.block) ? authored.block : written.block
        )
      end

      def keep_written_return?(authored, return_defaulted)
        return_defaulted && untyped?(authored.type.return_type)
      end

      # `(?)` on the inline side states no parameters at all, so the `sig/` list stands; `(?)` on the `sig/` side
      # has no slots to pair, so the authored list replaces it.
      def merge_function(authored, written)
        return written.with_return_type(authored.return_type) if untyped_function?(authored)
        return authored if untyped_function?(written)
        return nil unless same_shape?(authored, written)

        authored.update(
          required_positionals: pick_all(authored.required_positionals, written.required_positionals),
          optional_positionals: pick_all(authored.optional_positionals, written.optional_positionals),
          rest_positionals: pick(authored.rest_positionals, written.rest_positionals),
          trailing_positionals: pick_all(authored.trailing_positionals, written.trailing_positionals),
          required_keywords: pick_keywords(authored.required_keywords, written.required_keywords),
          optional_keywords: pick_keywords(authored.optional_keywords, written.optional_keywords),
          rest_keywords: pick(authored.rest_keywords, written.rest_keywords)
        )
      end

      def same_shape?(authored, written)
        %i[required_positionals optional_positionals trailing_positionals].all? do |slot|
          authored.public_send(slot).size == written.public_send(slot).size
        end &&
          authored.rest_positionals.nil? == written.rest_positionals.nil? &&
          authored.rest_keywords.nil? == written.rest_keywords.nil? &&
          authored.required_keywords.keys.sort == written.required_keywords.keys.sort &&
          authored.optional_keywords.keys.sort == written.optional_keywords.keys.sort
      end

      def pick_all(authored, written)
        authored.zip(written).map { |a, w| pick(a, w) }
      end

      def pick_keywords(authored, written)
        authored.to_h { |name, param| [name, pick(param, written.fetch(name))] }
      end

      # The authored parameter, unless its type is `untyped`; the name is the author's when the `sig/` one has
      # none to keep.
      def pick(authored, written)
        return written if authored.nil? || untyped?(authored.type)

        authored
      end

      # rbs-inline's default for an unannotated `&block` is `?{ (?) -> untyped }`; a block the inline side does
      # not declare at all is no statement either.
      def authored_block?(block)
        return false if block.nil?

        !(untyped_function?(block.type) && untyped?(block.type.return_type))
      end

      def untyped_function?(function)
        function.is_a?(::RBS::Types::UntypedFunction)
      end

      def untyped?(type)
        type.is_a?(::RBS::Types::Bases::Any)
      end
    end
  end
end
