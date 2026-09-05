# frozen_string_literal: true

module Rigor
  module SigGen
    # The RBS surface of a class the runtime builds from `Data.define(...)` / `Struct.new(...)` — its ancestry, its
    # synthesised member accessors, and its constructors — rendered from an ADR-48 member layout.
    #
    # Declaring the class without them would be worse than not declaring it at all. `::Data`'s own RBS declares
    # `def self.new: () -> bot` and `::Struct`'s declares only the `Struct.new("Name", :a, :b)` factory, so a
    # subclass that carries no `.new` of its own turns every `Point.new(1, 2)` into a false-positive arity error —
    # where the undeclared class it replaced merely typed as `Dynamic` and reported nothing. The same reasoning
    # covers the member readers and `.[]` (`Point[1, 2]`, which `::Data`'s RBS does not declare): narrowing dispatch
    # from `Dynamic` to a nominal class means everything the runtime synthesises must be declared, or it reads as
    # missing.
    #
    # Member types arrive already erased to RBS and already parenthesised for return position. One pre-wrapped
    # string serves every position this module interpolates into — `(a: (String | Integer))`,
    # `((String | Integer) a)`, `?(String | Integer) a` all parse and validate.
    module MetaClassShape
      # `::Struct` is generic (`class Struct[E]`), and RBS rejects a bare `< ::Struct` with
      # `InvalidTypeApplicationError`. `untyped` is the only element type a layout can justify.
      SUPERCLASSES = { data: "::Data", struct: "::Struct[untyped]" }.freeze

      # `method_name` / `kind` feed the writer's existing-member matching. `source_member` is the layout member a
      # reader / writer derives from, and nil for a constructor, so the caller can attach the member's carrier to
      # the candidate it builds.
      Member = ::Data.define(:method_name, :kind, :rbs, :source_member)
      Shape = ::Data.define(:superclass, :member_decls)

      module_function

      # @param members [Array<Symbol>] ordered member names from the ADR-48 layout.
      # @param member_types [Hash{Symbol => String}] erased RBS spellings; a member with no entry renders `untyped`.
      # @param keyword_init [Boolean] the `Struct.new(..., keyword_init: true)` flag; ignored for `:data`.
      def of(kind:, members:, member_types: {}, keyword_init: false)
        types = members.to_h { |member| [member, member_types[member] || "untyped"] }
        accessors = kind == :struct ? struct_accessors(members, types) : readers(members, types)
        Shape.new(superclass: SUPERCLASSES.fetch(kind),
                  member_decls: accessors + constructors(kind, members, types, keyword_init))
      end

      def readers(members, types)
        members.map do |member|
          Member.new(method_name: member, kind: :instance, source_member: member,
                     rbs: "def #{member}: () -> #{types[member]}")
        end
      end

      # A Struct's members are mutable, so each one contributes a writer too. The writer returns the assigned
      # value's type — Ruby's assignment semantics, and the spelling the `attr_writer` path already emits.
      def struct_accessors(members, types)
        writers = members.map do |member|
          Member.new(method_name: :"#{member}=", kind: :instance, source_member: member,
                     rbs: "def #{member}=: (#{types[member]}) -> #{types[member]}")
        end
        readers(members, types) + writers
      end

      # `.new` and its `.[]` alias share one overload list.
      def constructors(kind, members, types, keyword_init)
        overloads = constructor_overloads(kind, members, types, keyword_init).join(" | ")
        %i[new []].map do |name|
          Member.new(method_name: name, kind: :singleton, source_member: nil, rbs: "def self.#{name}: #{overloads}")
        end
      end

      # `Data` requires every member; a Struct fills a missing one with `nil`, so its positions are all optional.
      #
      # `keyword_init: true` accepts keyword arguments only. Every other layout gets BOTH forms, because the flag
      # reads `false` for an absent `keyword_init:` as well as for a literal `keyword_init: false` — and since Ruby
      # 3.2 the absent case, by far the dominant one, accepts both. Emitting both is the false-positive-free reading
      # of an ambiguity the layout cannot resolve.
      def constructor_overloads(kind, members, types, keyword_init)
        optional = kind == :struct ? "?" : ""
        keyword = "(#{members.map { |m| "#{optional}#{m}: #{types[m]}" }.join(', ')}) -> instance"
        return [keyword] if kind == :struct && keyword_init

        [keyword, "(#{members.map { |m| "#{optional}#{types[m]} #{m}" }.join(', ')}) -> instance"]
      end
    end
  end
end
