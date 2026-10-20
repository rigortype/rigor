# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    # Issue #2021 — the files a run analyses outside the configured `paths:` load through `require_relative`.
    #
    # A run over path arguments widens its discovery to the configured paths (#684), which is the whole project for
    # a file inside them. A file outside them has no such project: `rigor check plugins/x/lib/rigor/plugin/x.rb`
    # in a repository whose `paths:` is `lib` discovered `x.rb` and `lib` alone. The plugin's nested `Effects`,
    # declared in the sibling `x/effects.rb`, was then invisible, the lexical lookup fell through to the
    # project's `Rigor::Effects`, and every call on it drew a false `call.undefined-method` that checking the
    # plugin's `lib` did not.
    #
    # The file names its siblings itself: Ruby loads what it `require_relative`s before any of its code runs, so
    # those declarations are in scope at runtime. {.closure} follows that graph from the out-of-paths files,
    # through each target that is itself outside the configured paths. A target under a configured path is
    # already discovered and stops the walk there, so the files inside `paths:` are discovered exactly as a run
    # over the configured paths discovers them. Only a string literal counts (`require_relative "a/b"`, with or
    # without the `.rb`); a computed name, `require`, `load` and `autoload` are not followed, so a gem's own
    # files and a Zeitwerk-loaded tree are not reached this way.
    module RequireRelativeClosure
      module_function

      # @param seeds — the analysed files outside the configured paths, as spelled by the run.
      # @param covered — `->(absolute_path) { Boolean }`, whether discovery already holds that file (or, for an
      #   excluded file, deliberately leaves it out); the walk does not add it or follow it.
      # @param read — `->(path) { String }`, the source of a file (an editor buffer's bytes for its file).
      # @return the targets reached, absolute, in walk order, each once; the seeds themselves are never listed.
      def closure(seeds, covered:, read:)
        seen = seeds.to_set { |path| File.absolute_path(path) }
        queue = seeds.dup
        found = []
        until queue.empty?
          path = queue.shift
          targets_of(path, read).each do |target|
            next if covered.call(target) || !seen.add?(target)

            found << target
            queue << target
          end
        end
        found
      end

      # The existing `.rb` files `path` names with a literal `require_relative`, absolute.
      def targets_of(path, read)
        source = read.call(path)
        return [] if source.nil?

        base = File.dirname(File.absolute_path(path))
        literal_features(Prism.parse(source).value).filter_map do |feature|
          target = File.expand_path(feature.end_with?(".rb") ? feature : "#{feature}.rb", base)
          target if File.file?(target)
        end
      rescue StandardError
        []
      end

      # In source order, so discovery meets the targets in the order Ruby loads them.
      def literal_features(root)
        calls = []
        stack = [root]
        until stack.empty?
          node = stack.pop
          calls << node if literal_feature(node)
          stack.concat(node.compact_child_nodes)
        end
        calls.sort_by { |call| call.location.start_offset }.filter_map { |call| literal_feature(call) }
      end

      def literal_feature(node)
        return nil unless node.is_a?(Prism::CallNode) && node.name == :require_relative && node.receiver.nil?

        arguments = node.arguments&.arguments
        return nil unless arguments&.size == 1 && arguments.first.is_a?(Prism::StringNode)

        arguments.first.unescaped
      end
    end
  end
end
