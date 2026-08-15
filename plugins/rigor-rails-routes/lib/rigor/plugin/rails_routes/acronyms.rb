# frozen_string_literal: true

require "prism"

require "rigor/source/literals"
require "rigor/source/node_children"

module Rigor
  module Plugin
    class RailsRoutes < Rigor::Plugin::Base
      # The project's own inflector acronyms (`inflect.acronym 'ActivityPub'`), read STATICALLY out of
      # `config/initializers/inflections.rb` — never executed, in keeping with ADR-39's note that
      # project-specific inflection rules are ingested by parsing that file rather than by running it.
      #
      # Why the controller-name composition needs them: `scope module: :activitypub` names
      # `ActivityPub::CollectionsController` in a project that registers the acronym, and
      # `Activitypub::CollectionsController` in one that does not. Rigor loads its own
      # `ActiveSupport::Inflector`, not the analysed application's, so the acronym table is empty there and
      # the plain camelization is the wrong name. On Mastodon that is 19 of 280 emitted roots — inert (they
      # match no declaration), but 19 live controllers left unrooted and therefore reported as dead.
      #
      # The correction is a RENAME, never an addition: applying it cannot grow the root set, so it cannot
      # move the report in the over-supply direction ADR-102 § Consequences warns about.
      module Acronyms
        module_function

        # @param contents [String, nil] the source of `config/initializers/inflections.rb`.
        # @return [Array<String>] declared acronyms in declaration order. Empty for a missing / unparseable
        #   file, or one that declares none — which leaves composition exactly as it was.
        def discover(contents)
          return [] if contents.nil? || contents.empty?

          result = Prism.parse(contents)
          return [] unless result.success?

          found = []
          walk(result.value) do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :acronym

            value = Rigor::Source::Literals.symbol_or_string_name(node.arguments&.arguments&.first)
            found << value if value && !value.empty?
          end
          found.uniq
        end

        # Rewrites the camel-case words of an already-camelized name into their acronym spelling.
        #
        # Operating on the camelized RESULT rather than re-implementing camelization keeps
        # `ActiveSupport::Inflector` the authority (ADR-39 forbids a local approximation): the only thing
        # done here is substituting one spelling of a word for another. A word matches when the plain
        # camelization of the acronym appears at a camel-word boundary — `Oauth` in `OauthMetadata` and in
        # `WellKnown::Oauth`, but never the `Oauth` inside a hypothetical `Xoauth`.
        #
        # @param name [String] e.g. `"Activitypub::CollectionsController"`.
        # @param acronyms [Enumerable<String>] as returned by {.discover}.
        # @return [String] e.g. `"ActivityPub::CollectionsController"`.
        def apply(name, acronyms)
          acronyms.reduce(name) do |current, acronym|
            plain = Rigor::Plugin::Inflector.camelize(acronym.to_s.downcase)
            next current if plain == acronym.to_s

            current.gsub(boundary_pattern(plain), acronym.to_s)
          end
        end

        # A camel word starts at the beginning, after a `::` separator, or after the lowercase / digit tail
        # of the preceding word; it ends at the end, before a `::`, or before the next word's capital.
        def boundary_pattern(plain)
          /(?<=\A|::|[a-z0-9])#{Regexp.escape(plain)}(?=::|[A-Z]|\z)/
        end

        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node
          node.rigor_each_child { |child| walk(child, &) }
        end
      end
    end
  end
end
