# frozen_string_literal: true

require "prism"

module Rigor
  class Environment
    # ADR-82 WD9 — maps a top-level constant name to the locked, RBS-less gem that declares it, so an
    # unresolved constant read (`Faraday`, `Sidekiq`) can carry the `external_gem_without_rbs` provenance
    # cause instead of the generic `unsupported_syntax`. For a gem with no RBS the constant read is where the
    # class name is last visible — by dispatch time the receiver is already `Dynamic[top]` — so this index is
    # what lets `coverage --protection` route those holes to `add_rbs` honestly.
    #
    # Ownership is established by READING, never by guessing: each gem's conventional entry file
    # (`lib/<name>.rb`, with the dash → directory variant) is parsed with Prism and its top-level
    # class / module / constant declarations recorded under their root name. No gem code runs — the same
    # posture as ADR-72's "loads RBS data only" and the ADR-10 walker. A name-derivation heuristic
    # (`faraday` → `Faraday` by camelizing) is deliberately NOT used: it breaks on irregular names
    # (`activesupport` → `ActiveSupport`) and is exactly the guessing the ADR-82 honesty criterion forbids.
    #
    # Everything fails OPEN to "no owner": a gem that is not installed, an entry file that does not exist or
    # does not parse, a root constant declared only in a deeper file. An unindexed constant keeps today's
    # generic cause — the failure mode is a missing label, never a wrong one.
    #
    # The scan is bounded to entry files (one or two per gem) so building the index over a real app's
    # hundreds of RBS-less gems stays sub-second; it is built lazily on the first unresolved constant, so a
    # project whose constants all resolve never pays it.
    module MissingGemConstantIndex
      module_function

      # @param gems [Enumerable<Array(String, String)>] `[gem_name, version]` pairs (the `:missing` rows of
      #   {RbsCoverageReport}).
      # @param spec_resolver [#call] `(name, version) -> String?` returning the gem's installed root
      #   directory. Injectable for specs; the default consults RubyGems metadata only (no code load).
      # @return [Hash{String => String}] frozen `root constant name => gem name`. On a collision (two gems
      #   declaring the same top-level constant) the first gem wins — the CAUSE recorded downstream
      #   (external gem without RBS) is true under either owner.
      def build(gems, spec_resolver: method(:installed_gem_dir))
        index = {}
        gems.each do |gem_name, version|
          dir = spec_resolver.call(gem_name, version)
          next unless dir

          entry_files(dir, gem_name).each do |file|
            top_level_root_constants(file).each { |name| index[name] ||= gem_name }
          end
        end
        index.freeze
      end

      # RubyGems spec metadata lookup — the gem's on-disk source root, without loading any of its code.
      # Exact-version first (the Bundler-installed copy), any-version fallback for out-of-band installs.
      def installed_gem_dir(name, version)
        spec = begin
          Gem::Specification.find_by_name(name, "= #{version}")
        rescue Gem::LoadError
          begin
            Gem::Specification.find_by_name(name)
          rescue Gem::LoadError
            nil
          end
        end
        spec&.full_gem_path
      end

      # The conventional require targets for a gem name: `lib/foo.rb`, and `lib/foo/bar.rb` for a dashed
      # `foo-bar`. This is the require-name convention Bundler.require depends on — a filename convention,
      # not a constant-name guess; the constants come from parsing whichever of these exists.
      def entry_files(dir, gem_name)
        candidates = ["lib/#{gem_name}.rb"]
        candidates << "lib/#{gem_name.tr('-', '/')}.rb" if gem_name.include?("-")
        candidates.filter_map do |relative|
          path = File.join(dir, relative)
          path if File.file?(path)
        end
      end

      # Root names of the file's top-level declarations. Only direct children of the program are read — the
      # root constant of a gem's namespace is declared at file top level by construction (`module Faraday`,
      # `class Money::Error < …` roots at `Money`), so no recursion into bodies is needed.
      def top_level_root_constants(path)
        result = Prism.parse(File.read(path))
        return [] unless result.errors.empty?

        result.value.statements.body.filter_map do |node|
          case node
          when Prism::ClassNode, Prism::ModuleNode then root_segment(node.constant_path)
          when Prism::ConstantWriteNode then node.name.to_s
          end
        end
      rescue StandardError
        []
      end

      def root_segment(node)
        current = node
        current = current.parent while current.is_a?(Prism::ConstantPathNode) && current.parent
        current.respond_to?(:name) && current.name ? current.name.to_s : nil
      end
    end
  end
end
