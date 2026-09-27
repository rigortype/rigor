# frozen_string_literal: true

require_relative "../declaration_walk/traversal"

module Rigor
  module Inference
    module ScopeIndexer
      # The as-written superclass table and its issue #682 header-nesting twin (ADR-24 slice 2), as a
      # {DeclarationWalk} collector: each `class Foo < Bar` header's superclass name and the `Module.nesting`
      # its header sits in, plus the superclass of a `Class.new(Parent) { … }` block under that anonymous
      # class's synthetic name (#319). One walk builds both tables, so a caller never pairs a superclass
      # with a nesting from a different parse.
      class SuperclassesCollector
        include DeclarationWalk::Collector

        # The two rules `walk_class_superclasses` answered differently from the walk, kept so both tables stay
        # byte-identical (ADR-116 WD5). Each is a legacy answer, and #1521 tracks converging it:
        #
        # - `factory_block: :ordinary_call` — the legacy walker had no bare-factory arm, so it walked
        #   `Class.new { … }` as any call, block parameters included, with the enclosing `self`. A
        #   `class self::E < S` in that block is filed under the enclosing class (`C::E`), a class Ruby never
        #   creates (#1521 item 8).
        # - `anonymous_class_path: :outside_class_bodies` — the legacy walker dropped the file path when it
        #   entered a class/module, meta-new or eval-family body, but not a `class <<` body, so an anonymous
        #   class created inside a class body is keyed without the path the other tables give it (#1521 item
        #   11).
        VARIANTS = { factory_block: :ordinary_call, anonymous_class_path: :outside_class_bodies }.freeze

        def initialize
          @accumulator = { superclasses: {}, header_nestings: {} }
          # Read through the class, as the walk reads `factory_block`, so a subclass that overrides `VARIANTS`
          # gets one answer from both.
          @path_variant = DeclarationWalk::Collector.variant_of(self.class, :anonymous_class_path)
        end

        # A header that still names its class records its ancestry: an unnameable one (`class D` below
        # `class <<`) would publish facts for a `C::D` Ruby never creates. The nesting recorded is the one
        # OUTSIDE the header, because the header is evaluated before its body is entered.
        def on_declaration(node, context, body)
          unless body.singleton_cref
            ScopeIndexer.record_declaration_ancestry(node, context.nesting, body.prefix, @accumulator)
          end
          DeclarationWalk::DESCEND
        end

        # Only a `Class.new(Parent) { … }` with a literal block records anything, so a call without one is
        # passed over before the path is looked up.
        def on_call(node, context)
          if node.block.is_a?(Prism::BlockNode)
            path = context.anonymous_class_path(@path_variant)
            ScopeIndexer.record_anonymous_meta_superclass(node, @accumulator[:superclasses], path)
          end
          DeclarationWalk::DESCEND
        end

        # `[superclasses, header_nestings]`, each frozen, as {ScopeIndexer.build_superclass_tables} returns
        # them.
        def tables
          [@accumulator[:superclasses].freeze, @accumulator[:header_nestings].freeze]
        end
      end
    end
  end
end
