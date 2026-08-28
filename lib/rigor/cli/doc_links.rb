# frozen_string_literal: true

module Rigor
  class CLI
    # Turns the documentation's own relative links into keys `rigor docs` can answer (#430).
    #
    # The manual and handbook link each other and the design corpus the way any prose does —
    # `[ADR-103](../adr/103-effect-labels.md)`. Those links are correct in the repository and correct on
    # GitHub, and they are the coupling between documents: they say which document explains what, and
    # deleting them to leave a bare `ADR-103` would cost that and give nothing back.
    #
    # They are wrong in exactly one place: a reader looking at the file inside an installed gem, where
    # `docs/adr/` was never packaged. Two earlier attempts fixed the file for that reader and made it
    # worse for the others — rewriting every link to a `blob/master` URL hardcoded a host, an
    # organisation and a branch in 297 places and sent a v0.3.5 reader to a document that had moved on;
    # deleting the markup severed the coupling.
    #
    # So the source keeps its links and `rigor docs` rewrites them on the way out:
    #
    #     [ADR-103](../adr/103-effect-labels.md)   →   [ADR-103][adr/103-effect-labels]
    #
    # The key is the repository path minus `docs/` and `.md`, which for a packaged page is exactly the
    # name `rigor docs` already takes, so the reader can run what they are shown. For an unpackaged one
    # the key still resolves — to a routed message naming the path and the repository, from the single
    # constant below rather than from 297 rewritten links.
    module DocLinks
      REPOSITORY = "https://github.com/rigortype/rigor"

      # `[label](target)` and `[label](target#anchor)`, skipping absolute URLs and bare anchors.
      MARKDOWN_LINK = /\[([^\]]*)\]\((?!https?:|mailto:|#)([^)#\s]+)(#[^)\s]*)?\)/
      private_constant :MARKDOWN_LINK

      # Where the gem's `docs/` tree sits, so a rendered path can be made repository-relative.
      GEM_ROOT = File.expand_path("../../..", __dir__)
      private_constant :GEM_ROOT

      module_function

      # @param body [String] the page as it is stored.
      # @param from [String] its absolute path, so relative targets resolve.
      # @return [String] the page with every relative link turned into a `rigor docs` key.
      def rewrite(body, from:)
        dir = File.dirname(from)
        body.gsub(MARKDOWN_LINK) do
          label = Regexp.last_match(1)
          target = Regexp.last_match(2)
          anchor = Regexp.last_match(3)
          key = key_for(target, dir)
          key.nil? ? "[#{label}](#{target}#{anchor})" : "[#{label}][#{key}#{anchor}]"
        end
      end

      # Splits a key into its page and its section, for a reader who pasted one back.
      def split_anchor(key)
        page, anchor = key.to_s.split("#", 2)
        [page, anchor]
      end

      # The key naming `target` as written in `dir`, or nil when it points outside the repository.
      #
      # A `.md` under `docs/` loses both the prefix and the extension, which is exactly the name
      # `rigor docs` already answers — that is what lets a rendered page hand the reader something they
      # can run. Everything else keeps its repository-relative path verbatim: a directory
      # (`examples/rigor-deprecations/`), a source file (`spec/rigor/environment_spec.rb`), a root
      # document (`CHANGELOG.md`). Those are equally routable and equally worth naming; only the
      # round-trip differs, and {.repository_path} reverses both.
      #
      # `target` is taken as written rather than expanded, because `File.expand_path` drops the trailing
      # slash that tells a directory link apart from a page link — prose that writes `[the ADRs](../adr/)`
      # is pointing at a tree, and a key without the slash would claim there is a page there.
      def key_for(target, dir)
        relative = File.expand_path(target, dir).sub("#{GEM_ROOT}/", "")
        return nil if relative.start_with?("/")

        relative += "/" if target.end_with?("/")
        return relative unless relative.start_with?("docs/") && relative.end_with?(".md")

        relative.delete_prefix("docs/").delete_suffix(".md")
      end

      # Repository directories a key may name verbatim. A key that starts with one of these already IS a
      # path — `docs/adr`, `plugins/rigor-sorbet` — because {.key_for} only rewrites `.md` files under
      # `docs/`. Anything else is a documentation key and gets its prefix and extension back.
      #
      # Keying on the ROOT rather than on "has an extension" is what makes a directory work: prose links
      # a tree as often without a trailing slash (`../adr`) as with one, and no string test tells an
      # extensionless file from a directory.
      REPOSITORY_ROOTS = %w[docs examples plugins spec skills data tool bench apps].freeze

      # The repository path a key names, reversing {.key_for}.
      def repository_path(key)
        return nil if key.nil? || key.empty? || key.include?("..")
        return key if REPOSITORY_ROOTS.include?(key.split("/").first)
        return key if File.extname(key) != ""

        "docs/#{key}.md"
      end
    end
  end
end
