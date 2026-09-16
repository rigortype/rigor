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
    # alias whose own expansion erases to the same member SET? The comparison is deliberately a set, not a
    # string: a union missing one arm is a different type and must keep printing in full.
    #
    # Scope and conservatism, in the order they matter:
    #
    # - **Project aliases only.** An entry is kept only when its declaration's buffer is one of the `.rbs`
    #   files under the project's own `signature_paths:`. Gem and stdlib RBS declare aliases (`int`, `string`,
    #   `Prism::node`, ...) that a reader of a proposal did not choose and would not expect to see; folding
    #   into those would rewrite proposals for projects that never opted in.
    # - **Unions only.** An alias whose expansion is a single type (`type name = String`) is never folded.
    #   Folding those would rewrite ordinary `String` returns across a whole project, and the noise the issue
    #   is about is specifically the long union.
    # - **Non-generic only.** A generic alias's expansion depends on its arguments, so there is no fixed
    #   member set to key on.
    # - **Same pipeline on both sides.** The stored key is produced by translating the alias body through
    #   {Inference::RbsTypeTranslator} and then running {TypeElaborator} + `erase_to_rbs` — the exact steps
    #   `Generator#elaborated_rbs` runs on an inferred carrier. A difference in elaboration (bare `Array`
    #   filled in to `Array[untyped]`, say) therefore cancels on both sides instead of causing a near miss.
    #
    # A project with no aliases builds an empty index, and an empty index is a no-op: `#fold` returns its
    # argument, so the rendered output is byte-identical to the pre-#1002 output.
    class AliasIndex
      # @return an index with no entries — {#fold} is the identity.
      def self.empty
        new({})
      end

      # Builds the index from the environment's RBS loader. Fail-soft in the ADR-5 sense: any loader that
      # cannot answer the two accessors this needs, and any alias whose body fails to translate, yields an
      # entry-free index rather than an error, because a rendering nicety must never fail a run.
      def self.build(environment:)
        loader = environment&.rbs_loader
        return empty unless loader.respond_to?(:each_type_alias_decl) && loader.respond_to?(:signature_paths)

        project_files = project_sig_files(loader.signature_paths)
        return empty if project_files.empty?

        new(collect_entries(loader, project_files, environment))
      end

      # Every `.rbs` file under the project's own `signature_paths:`, absolute. Vendored gem stubs and the
      # stdlib tree are loaded from elsewhere, so this set is exactly "aliases this project wrote".
      def self.project_sig_files(signature_paths)
        Array(signature_paths).flat_map do |path|
          dir = path.is_a?(Pathname) ? path : Pathname(path.to_s)
          next [] unless dir.directory?

          Dir.glob(dir.join("**", "*.rbs").to_s).map { |p| File.expand_path(p) }
        end.to_set
      end

      def self.collect_entries(loader, project_files, environment)
        entries = {}
        loader.each_type_alias_decl do |type_name, decl_entry|
          entry = build_entry(loader, project_files, environment, type_name, decl_entry)
          next if entry.nil?

          key = entry[:members]
          entries[key] = entry if entries[key].nil? || preferred?(entry, entries[key])
        end
        entries.transform_values { |entry| entry[:name] }
      end

      # The tie-break rule the issue asks to be stated and pinned: when two project aliases expand to the same
      # member set, the winner is the one whose DECLARATION POSITION sorts first, by (declaration file path,
      # start line, fully-qualified name). All three components come off the declaration itself, so the winner
      # is the same on every run and on every machine — the order `each_type_alias_decl` happens to yield (an
      # `RBS::Environment` Hash) is never consulted. The name breaks the remaining tie for a declaration whose
      # location RBS did not record.
      def self.preferred?(candidate, incumbent)
        (candidate[:order] <=> incumbent[:order]).negative?
      end

      def self.build_entry(loader, project_files, environment, type_name, decl_entry)
        decl = decl_entry.respond_to?(:decl) ? decl_entry.decl : nil
        return nil if decl.nil?
        return nil if decl.respond_to?(:type_params) && !Array(decl.type_params).empty?

        file = declaration_file(decl)
        return nil unless file && project_files.include?(file)

        members = expanded_members(loader, environment, decl)
        return nil if members.nil?

        name = type_name.to_s.delete_prefix("::")
        { members: members, name: name, order: [file, declaration_line(decl), name] }
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

      # nil whenever the alias is not usable as a rendering target: an untranslatable body, a body that erases
      # to `untyped` (the gradual-consistency collapse in `Type::Union#erase_to_rbs`, which would otherwise key
      # every such alias on the same one-member set), or a single-type body.
      def self.expanded_members(loader, environment, decl)
        translated = Inference::RbsTypeTranslator.translate(
          decl.type, self_type: nil, instance_type: nil, type_vars: {}, alias_expander: loader
        )
        return nil if translated.nil?

        erased = TypeElaborator.elaborate(translated, environment: environment).erase_to_rbs
        members = split_top_level(erased)
        members.size < 2 ? nil : members
      rescue StandardError
        nil
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

      def initialize(entries)
        @entries = entries
      end

      # @return the alias name when `rendered` is exactly some project alias's expansion, else
      #   `rendered` unchanged. Callers can apply this unconditionally.
      def fold(rendered)
        return rendered if @entries.empty? || !rendered.include?("|")

        members = self.class.split_top_level(rendered)
        return rendered if members.size < 2

        @entries.fetch(members, rendered)
      end

      def empty?
        @entries.empty?
      end
    end
  end
end
