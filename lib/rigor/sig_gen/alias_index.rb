# frozen_string_literal: true

require_relative "../inference/rbs_type_translator"
require_relative "type_elaborator"

module Rigor
  module SigGen
    # Issue #1002 — the WRITE direction of a project's own type aliases.
    #
    # `Generator`'s `alias_expander:` wiring (PR #1000) reads a declared alias: `-> Type::t` in the project's
    # `sig/` becomes the 22-member union so a proposal can be compared against it. Nothing went the other way,
    # so a proposal that inferred exactly that union printed all 22 members — output an author cannot paste,
    # because review rewrites it back into the alias the project already declares.
    #
    # This index answers the reverse lookup: given the RBS a proposal erased to, is there a project-declared
    # alias whose own expansion erases to the same member SET, close enough to the method's own namespace to
    # be the name a reader expects? The comparison is deliberately a set, not a string: a union missing one
    # arm is a different type and must keep printing in full.
    #
    # A wrong alias name is worse than a long union — it is an RBS claim the author did not make and may not
    # hold — so every rule below refuses rather than guesses.
    #
    # - **Project aliases only.** The candidate `.rbs` files come from the configuration's OWN resolved
    #   `signature_paths:` (what `Environment.for_project` calls `resolved_paths`), passed in by the caller.
    #   Deliberately NOT `RbsLoader#signature_paths`: that is `resolved_paths` PLUS plugin signature paths,
    #   bundler-discovered gem `sig/` directories, the `rbs collection` tree and Rigor's own gem overlays.
    #   Keyed off the loader, a project that merely bundles a gem shipping RBS aliases would find that gem's
    #   vocabulary in its proposals. A loaded plugin's own `sig/` is subtracted even when the project wired
    #   it through `signature_paths:` itself (the #697 shape) — it is the plugin's vocabulary either way.
    # - **Lossless alias bodies only.** Neither translation nor erasure is injective. `Type::Intersection`
    #   erases to its FIRST member, `Refined` and `Difference` to their base, a proc type translates to a
    #   bare `Proc`, and an RBS intersection may not even survive translation. An alias
    #   `type inter = (Integer & Comparable) | String` therefore reaches the renderer indistinguishable from
    #   `Integer | String`, and folding a proposal that really is `Integer | String` into `inter` would claim
    #   an intersection the method never returns — RBS an author cannot accept. So the alias body is checked
    #   on BOTH sides of translation, each an ALLOW-list ({.lossless_rbs?} over the RBS AST,
    #   {.lossless?} over the translated carriers). Anything absent — including a form added after this was
    #   written, and a nested alias reference, whose own body this walk does not see — disqualifies the
    #   alias. Refusing to fold is always safe; naming the wrong type is not.
    # - **Namespace proximity.** Type equality is not enough to make a name right for the reader.
    #   `:positive | :negative` is type-equal to this repository's `Analysis::FactStore::polarity` from
    #   anywhere in the tree, and naming it inside an unrelated class is a worse proposal than the union. An
    #   alias is only offered to a method whose owner is inside the alias's own namespace, and the NEAREST
    #   such alias wins.
    # - **Unions only.** An alias whose expansion is a single type (`type name = String`) is never folded;
    #   the noise the issue is about is specifically the long union.
    # - **Non-generic only.** A generic alias's expansion depends on its arguments, so there is no fixed
    #   member set to key on.
    #
    # A project with no aliases builds an empty index, and an empty index is a no-op: `#fold` returns its
    # argument, so the rendered output is byte-identical to the pre-#1002 output.
    class AliasIndex
      # The carriers whose `erase_to_rbs` is faithful enough to key on. Everything absent is disqualifying,
      # which is why this is a list of names resolved lazily rather than a `case`: a new carrier is excluded
      # until someone establishes its erasure round-trips.
      LOSSLESS_CARRIERS = %i[Top Bot Constant Nominal Singleton Union Tuple Maybe IntegerRange FloatRange].freeze
      private_constant :LOSSLESS_CARRIERS

      # A proc type translates to a bare `Proc` nominal, losing the signature, so an alias mentioning one
      # cannot be keyed on its erasure either.
      PROC_CLASS_NAMES = ["Proc", "::Proc"].freeze
      private_constant :PROC_CLASS_NAMES

      # The RBS forms whose meaning survives translation AND erasure. Notable absences, each a form that
      # reaches the renderer looking like something narrower or wider than it is: `Intersection`, `Proc`,
      # `Record`, `Interface`, `Alias` (its body is expanded during translation, out of this walk's sight),
      # `untyped` / `void` / `top`, and every context-dependent base (`self`, `instance`, `class`).
      LOSSLESS_RBS_TYPES = %w[
        RBS::Types::ClassInstance RBS::Types::ClassSingleton RBS::Types::Union RBS::Types::Optional
        RBS::Types::Tuple RBS::Types::Literal RBS::Types::Bases::Nil RBS::Types::Bases::Bool
        RBS::Types::Bases::Bottom
      ].freeze
      private_constant :LOSSLESS_RBS_TYPES

      # @return an index with no entries — {#fold} is the identity.
      def self.empty
        new({})
      end

      # @param signature_paths — the project's OWN resolved signature paths.
      # @param excluded_paths — signature paths that reached the list from somewhere other than the
      #   author: a loaded plugin's own `sig/`, which #697 lets a project wire through `signature_paths:`
      #   as well. Those aliases are the plugin's vocabulary, not this project's.
      #   Fail-soft in the ADR-5 sense: a loader that cannot enumerate aliases, and any alias whose body fails
      #   to translate, yields an entry-free index rather than an error, because a rendering nicety must never
      #   fail a run.
      def self.build(environment:, signature_paths:, excluded_paths: [])
        loader = environment&.rbs_loader
        return empty unless loader.respond_to?(:each_type_alias_decl)

        project_files = project_sig_files(signature_paths) - project_sig_files(excluded_paths)
        return empty if project_files.empty?

        new(collect_entries(loader, project_files, environment))
      end

      # Every `.rbs` file under the given signature paths, absolute. Directories only, matching `RbsLoader`,
      # which skips a `signature_paths:` entry that is not a directory.
      def self.project_sig_files(signature_paths)
        Array(signature_paths).flat_map do |path|
          dir = path.is_a?(Pathname) ? path : Pathname(path.to_s)
          next [] unless dir.directory?

          Dir.glob(dir.join("**", "*.rbs").to_s).map { |p| File.expand_path(p) }
        end.to_set
      end

      # `{ member set => entries sorted by declaration position }`. Every alias matching a set is kept, not
      # just one: which of them is the right NAME depends on the method being rendered, and that is only
      # known at {#fold} time.
      def self.collect_entries(loader, project_files, environment)
        entries = Hash.new { |h, k| h[k] = [] }
        loader.each_type_alias_decl do |type_name, decl_entry|
          entry = build_entry(loader, project_files, environment, type_name, decl_entry)
          entries[entry[:members]] << entry unless entry.nil?
        end
        entries.each_value { |list| list.sort_by! { |entry| entry[:order] } }
        entries.default_proc = nil
        entries
      end

      def self.build_entry(loader, project_files, environment, type_name, decl_entry)
        decl = decl_entry.respond_to?(:decl) ? decl_entry.decl : nil
        return nil if decl.nil?
        return nil if decl.respond_to?(:type_params) && !Array(decl.type_params).empty?

        file = declaration_file(decl)
        return nil unless file && project_files.include?(file)

        members = expanded_members(loader, environment, decl)
        return nil if members.nil?

        # The ABSOLUTE spelling. RBS resolves a relative type name innermost-first, so a bare
        # `Deep::Inner::mood` written inside `Deep::Inner` would rebind if the project also declared a
        # `Deep::Inner::Deep`. The leading `::` says exactly which alias the proposal means.
        relative = type_name.to_s.delete_prefix("::")
        { members: members, name: "::#{relative}", namespace: relative.split("::")[0..-2].join("::"),
          order: [file, declaration_line(decl), relative] }
      end

      def self.declaration_file(decl)
        buffer_name = decl.location&.buffer&.name
        return nil if buffer_name.nil?

        File.expand_path(buffer_name.to_s)
      rescue StandardError
        nil
      end

      def self.declaration_line(decl)
        decl.location&.start_line || 0
      rescue StandardError
        0
      end

      # nil whenever the alias is not usable as a rendering target: an untranslatable body, a body carrying a
      # carrier whose erasure loses information, a body that erases to `untyped` (the gradual-consistency
      # collapse in `Type::Union#erase_to_rbs`, which would otherwise key every such alias on the same
      # one-member set), or a single-type body.
      def self.expanded_members(loader, environment, decl)
        return nil unless lossless_rbs?(decl.type)

        translated = Inference::RbsTypeTranslator.translate(
          decl.type, self_type: nil, instance_type: nil, type_vars: {}, alias_expander: loader
        )
        return nil if translated.nil? || !lossless?(translated)

        erased = TypeElaborator.elaborate(translated, environment: environment).erase_to_rbs
        members = split_top_level(erased)
        members.size < 2 ? nil : members
      rescue StandardError
        nil
      end

      # The RBS-AST half of the check, and the one that catches an intersection: `(Integer & Comparable)`
      # does not necessarily survive translation as a `Type::Intersection`, so by the time the carrier walk
      # runs there is nothing left to notice.
      def self.lossless_rbs?(rbs_type)
        return false unless LOSSLESS_RBS_TYPES.include?(rbs_type.class.name)
        return true unless rbs_type.respond_to?(:each_type)

        children = []
        rbs_type.each_type { |child| children << child }
        children.all? { |child| lossless_rbs?(child) }
      end

      # The carrier half, a backstop for what translation itself invents (a `Refined` or `Difference` from a
      # `rigor:` envelope, a bare `Proc` from a proc type reached some other way). Walks the TRANSLATED
      # tree, so it also sees a construct the RBS walk could not reach.
      def self.lossless?(type)
        carrier = type.class.name.to_s.split("::").last&.to_sym
        return false unless LOSSLESS_CARRIERS.include?(carrier)
        return false if carrier == :Nominal && PROC_CLASS_NAMES.include?(type.class_name.to_s)

        children_of(type).all? { |child| lossless?(child) }
      end

      def self.children_of(type)
        case type
        when Type::Union then type.members
        when Type::Tuple then type.elements
        when Type::Maybe then [type.value_type]
        when Type::Nominal then type.type_args
        else []
        end
      end

      # Splits an erased RBS string on its TOP-LEVEL `|` separators. Depth tracking keeps a nested union
      # (`Array[A | B]`) whole, and the quote state keeps a literal string type (`"a | b"`) whole.
      def self.split_top_level(rendered)
        members = []
        current = +""
        depth = 0
        quote = nil
        rendered.each_char do |ch|
          if quote
            current << ch
            quote = nil if ch == quote
            next
          end

          case ch
          when '"', "'" then quote = ch
          when "(", "[", "{" then depth += 1
          when ")", "]", "}" then depth -= 1
          when "|"
            if depth.zero?
              members << current.strip
              current = +""
              next
            end
          end
          current << ch
        end
        members << current.strip
        members.reject(&:empty?).to_set
      end

      # The namespaces a method owned by `owner` can name an alias from, INNERMOST FIRST: its own namespace,
      # then each enclosing one, ending at the top level. `nil`/`""` for a top-level owner still reaches the
      # top-level namespace, which is where an adopting project's `type` declarations usually live.
      def self.namespace_chain(owner)
        segments = owner.to_s.split("::")
        segments.size.downto(0).map { |i| segments[0...i].join("::") }
      end

      def initialize(entries)
        @entries = entries
      end

      # @param owner — the class or module the rendered member belongs to; `nil` renders unchanged,
      #   because proximity cannot be judged without it.
      # @return the alias name when `rendered` is exactly some in-scope project alias's expansion,
      #   else `rendered` unchanged. Callers can apply this unconditionally.
      def fold(rendered, owner)
        return rendered if @entries.empty? || owner.nil? || !rendered.include?("|")

        members = self.class.split_top_level(rendered)
        return rendered if members.size < 2

        candidates = @entries[members]
        return rendered if candidates.nil? || candidates.empty?

        nearest(candidates, owner) || rendered
      end

      def empty?
        @entries.empty?
      end

      private

      # "Most specific, then declaration order", the rule the issue asked to have stated and pinned. The
      # chain index is the distance from the method's own namespace outwards, so an alias declared beside the
      # method beats one declared in an enclosing namespace, and `candidates` is already in declaration order
      # ((file, line, name)), which `min_by` keeps as the tie-break. An alias whose namespace does not
      # enclose the owner at all is not a candidate: it names the right type under a name this reader has no
      # reason to expect.
      def nearest(candidates, owner)
        chain = self.class.namespace_chain(owner)
        best = candidates.each_with_index.filter_map do |entry, position|
          distance = chain.index(entry[:namespace])
          distance.nil? ? nil : [[distance, position], entry[:name]]
        end.min_by(&:first)
        best&.last
      end
    end
  end
end
