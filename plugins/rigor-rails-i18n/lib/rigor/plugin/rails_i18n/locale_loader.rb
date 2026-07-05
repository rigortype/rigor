# frozen_string_literal: true

require "yaml"

require_relative "locale_index"

module Rigor
  module Plugin
    class RailsI18n < Rigor::Plugin::Base
      # Walks `locale_search_paths` for `.yml` / `.yaml` files, reads each through the trusted IoBoundary,
      # parses with `YAML.safe_load`, and folds the resulting nested hash into a flat `dotted_key => Entry`
      # table.
      #
      # The top-level YAML key is the locale (`en:`, `ja:`, …). Anything underneath is recursively
      # flattened into dotted keys (`users.welcome`, `errors.messages.blank`, …). For each leaf string,
      # `%{var}` placeholders are extracted via a simple regex.
      #
      # Files that fail to parse are skipped with a load-error diagnostic surfaced through the plugin's
      # error channel. Non-Hash YAML roots (e.g. a top-level sequence) are also skipped — the format is
      # locale-keyed by convention.
      class LocaleLoader
        PLACEHOLDER_RE = /%\{(?<name>[^}]+)\}/

        # Errno classes that indicate "this file is not readable as a YAML locale" — swallowed so a single
        # bad path doesn't take down the rest of the index.
        IO_ERRORS = [Errno::ENOENT, Errno::EACCES, Errno::EISDIR].freeze

        LoadError = Struct.new(:path, :message, keyword_init: true)

        attr_reader :load_errors

        def initialize(io_boundary:, search_paths:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @load_errors = []
        end

        # @return [LocaleIndex]
        def load
          per_key = {} # dotted_key => { locale => Set<String> }
          per_key_kinds = {} # dotted_key => { locale => :string|:array|:hash }
          locales = Set.new

          locale_files.each do |path|
            contents = read_safely(path)
            next if contents.nil?

            parsed = parse_yaml_safely(path, contents)
            next unless parsed.is_a?(Hash)

            parsed.each do |locale, tree|
              locale = locale.to_s
              locales << locale
              each_flattened(tree, []) do |dotted_key, value|
                placeholders = (per_key[dotted_key] ||= {})
                placeholders[locale] = extract_placeholders(value)
                kinds = (per_key_kinds[dotted_key] ||= {})
                kinds[locale] = classify_kind(value)
              end
            end
          end

          entries = per_key.map do |dotted_key, placeholder_map|
            LocaleIndex::Entry.new(
              dotted_key: dotted_key,
              placeholders: placeholder_map.freeze,
              value_kinds: per_key_kinds[dotted_key].freeze
            )
          end
          LocaleIndex.new(entries, locales: locales.to_a.sort)
        end

        private

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, *IO_ERRORS
          nil
        end

        def parse_yaml_safely(path, contents)
          YAML.safe_load(contents, aliases: true, permitted_classes: [Symbol])
        rescue Psych::SyntaxError => e
          @load_errors << LoadError.new(path: path, message: "YAML syntax error: #{e.message}")
          nil
        end

        def locale_files
          @search_paths.flat_map do |root|
            absolute = File.expand_path(root)
            next [] unless File.directory?(absolute)

            Dir.glob(File.join(absolute, "**", "*.{yml,yaml}"))
          end.sort
        end

        # Recursively walks the per-locale subtree, yielding `[dotted_key, leaf_value]` for each leaf. Hash
        # leaves are *not* recorded as entries themselves — only their descendants — but every leaf scalar
        # / array IS recorded.
        #
        # `breadcrumbs` is a single mutable stack reused across the whole walk (push before recursing, pop
        # after): for the 530-file / 14 MB Mastodon locale corpus the old
        # `flat_map { flatten_tree(v, breadcrumbs + [k]) }` shape allocated a fresh breadcrumb Array at
        # every node plus an intermediate result Array at every level — millions of short-lived objects and
        # the run's top allocation site. The dotted key is still materialised once per leaf (it has to
        # be); everything else is now allocation-free traversal.
        def each_flattened(node, breadcrumbs, &)
          if node.is_a?(Hash)
            node.each do |k, v|
              breadcrumbs.push(k.to_s)
              each_flattened(v, breadcrumbs, &)
              breadcrumbs.pop
            end
          else
            yield breadcrumbs.join("."), node
          end
        end

        def extract_placeholders(value)
          case value
          when String
            # Most locale leaves carry no `%{var}`; skip the scan + flatten + to_set allocation trio for
            # them. A string with no `%{` yields an empty placeholder set either way.
            return Set.new unless value.include?("%{")

            value.scan(PLACEHOLDER_RE).flatten.to_set
          when Array then value.map { |v| extract_placeholders(v) }.reduce(Set.new) { |a, s| a | s }
          else Set.new
          end
        end

        def classify_kind(value)
          case value
          when String then :string
          when Array then :array
          when Hash then :hash
          else :scalar
          end
        end
      end
    end
  end
end
