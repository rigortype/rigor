# frozen_string_literal: true

require "rbs"
require_relative "../rooted_glob"
require_relative "gated_signature_plan"

module Rigor
  class Environment
    # Issue #2470 — a `data/vendored_gem_sigs/<gem>/` member another signature source also declares stands down,
    # so the other source's declaration binds instead of the two failing the class's definition build.
    #
    # The vendored directories load on `RBS::EnvironmentLoader`'s batch path, ahead of the project's
    # `signature_paths:` (its own `sig/`, an `rbs collection install`, a gem's `sig/`). A file there that reopens
    # a vendored class and declares one of its methods again — the activerecord 8.1 collection's `patch.rbs`
    # writes `def async_exec` on `PG::Connection`, where the vendored `pg.rbs` has `alias async_exec exec` — made
    # `RBS::DefinitionBuilder` raise `DuplicatedMethodDefinitionError` for the class, which Rigor keeps known, so
    # every call into it read `Dynamic[top]`.
    #
    # {.build} is the #1713 member rule ({GatedSignaturePlan}) applied to the ungated directories, planned from
    # the signature files themselves rather than from a trial build: the vendored copy is Rigor's guess at a gem's
    # surface, and the project chose the other source, so the other source wins (`RbsLoader.build_env_for`'s
    # stated precedence). Only a directory with a member to leave out is planned; the rest stay on the batch path.
    # An overload continuation (`def m: ... | ...`) declares nothing of its own and keeps the vendored base.
    #
    # The plan is a pure function of the vendored files and the signature files, both of which the env-cache key
    # digests, so a cold and a warm run build the same environment.
    module VendoredSignaturePlan
      # `dirs` — the vendored directories (Pathnames) to keep off the batch path; `sources` — their files as
      # `[buffer, directives, decls]`, the taken members left out, to add right after the batch; `takers` — the
      # signature files a member stood down to. A member stands down only to a file that stays in the env: the
      # caller re-plans without each taker the build quarantined (`RbsLoader.build_env_attempt`), or the method
      # would have no declaration at all.
      Plan = Data.define(:dirs, :sources, :takers)
      EMPTY = Plan.new(dirs: [].freeze, sources: [].freeze, takers: Set.new.freeze)

      # A `class` / `module` header, after any `%a{...}` / `%a(...)` / `%a[...]` annotations on the same line.
      ANNOTATED_HEADER = /^\s*(?:%a(?:\{[^}]*\}|\([^)]*\)|\[[^\]]*\])\s*)*(?:class|module)\s+(?:::)?/

      module_function

      # @param roots — the ungated vendored directories this build loads.
      # @param signature_files — the absolute paths of the signature files that outrank them.
      # @param excluded — signature files to plan without: takers a previous build of this env quarantined.
      def build(roots, signature_files, excluded = Set.new)
        files = signature_files.reject { |file| excluded.include?(file) }
        return EMPTY if roots.empty? || files.empty?

        parsed = roots.to_h { |root| [root, parsed_sources(root)] }
        taken = taken_keys(files, header_pattern(parsed.values.flatten(1)))
        return EMPTY if taken.empty?

        takers = Set.new
        planned = parsed.filter_map do |root, sources|
          kept = plan_sources(sources, taken, takers)
          [root, kept] if kept
        end
        return EMPTY if planned.empty?

        Plan.new(dirs: planned.map(&:first), sources: planned.flat_map(&:last), takers: takers.freeze)
      end

      # A vendored directory's files, parsed, under the Pathname buffer names the loader's batch path gives them,
      # in the set `RBS::EnvironmentLoader#add(path:)` reads: every `.rbs` under it.
      def parsed_sources(root)
        RootedGlob.glob(root, "**/*.rbs").sort.filter_map { |file| RbsLoader.parse_signature_file(Pathname(file)) }
      end

      # `sources` with the taken members left out, or nil when nothing is taken from any of them.
      def plan_sources(sources, taken, takers)
        kept = sources.map do |buffer, directives, decls|
          [buffer, directives, plan_decls(decls, nil, taken, takers)]
        end
        kept unless kept.zip(sources).all? { |(_, _, after), (_, _, before)| unchanged?(after, before) }
      end

      # A header naming one of the vendored top-level types, which every declaration of a vendored type (nested or
      # `A::B`-qualified) starts from. A pre-filter only: the matches are parsed.
      def header_pattern(parsed)
        heads = parsed.flat_map do |_buffer, _directives, decls|
          decls.filter_map { |decl| GatedSignaturePlan.type_declaration?(decl) && decl.name.to_s.delete_prefix("::") }
        end
        segments = heads.map { |name| Regexp.escape(name.split("::").first) }.uniq
        return nil if segments.empty?

        /#{ANNOTATED_HEADER}(?:#{segments.join('|')})\b/
      end

      # `{type name => {[method, kind] => Set[file]}}` over the signature files that declare a vendored top-level
      # type.
      def taken_keys(signature_files, pattern)
        taken = Hash.new { |hash, name| hash[name] = Hash.new { |keys, key| keys[key] = Set.new } }
        return taken if pattern.nil?

        signature_files.sort.each do |file|
          text = RbsLoader.read_signature_text(file)
          next if text.nil? || !text.match?(pattern)

          decls = RbsLoader.parse_signature_source(file, text)
          collect_keys(decls, nil, taken, file) if decls
        end
        taken
      end

      def collect_keys(decls, namespace, taken, file)
        decls.each do |decl|
          next unless GatedSignaturePlan.type_declaration?(decl)

          name = GatedSignaturePlan.qualify(namespace, decl.name)
          decl.members.each do |member|
            RbsLoader.member_method_keys(member).each { |key| taken[name][key] << file }
          end
          collect_keys(decl.members, name, taken, file)
        end
      end

      # `decls` with every member `taken` declares for its type left out, nested types planned the same way, and
      # the files each left-out member stood down to added to `takers`. A declaration nothing is taken from is
      # returned as itself, which is how {.build} tells a directory unchanged.
      def plan_decls(decls, namespace, taken, takers)
        decls.map do |decl|
          next decl unless GatedSignaturePlan.type_declaration?(decl)

          plan_type(decl, GatedSignaturePlan.qualify(namespace, decl.name), taken, takers)
        end
      end

      def unchanged?(after, before)
        after.size == before.size && after.zip(before).all? { |a, b| a.equal?(b) }
      end

      def plan_type(decl, name, taken, takers)
        keys = taken.fetch(name, nil)
        members = decl.members.filter_map do |member|
          if GatedSignaturePlan.type_declaration?(member)
            plan_type(member, GatedSignaturePlan.qualify(name, member.name), taken, takers)
          elsif keys
            plan_member(member, keys, takers)
          else
            member
          end
        end
        return decl if unchanged?(members, decl.members)

        GatedSignaturePlan.rebuild(decl, members: members)
      end

      def plan_member(member, keys, takers)
        RbsLoader.member_method_keys(member).each { |key| takers.merge(keys[key]) if keys.key?(key) }
        GatedSignaturePlan.untaken(member, keys)
      end
    end
  end
end
