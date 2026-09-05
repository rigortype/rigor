# frozen_string_literal: true

require_relative "envelope"
require_relative "label_set"
require_relative "method_key"

module Rigor
  module Effects
    # Envelopes by **convention** — the `effects.envelopes:` block of `.rigor.yml` (ADR-103 WD5 (2);
    # design note § 6.2).
    #
    # ```yaml
    # effects:
    #   envelopes:
    #     - match: "app/presenters/**/*.rb"   # File.fnmatch, project-relative — the ADR-28 shape
    #       effect: []                        # the empty envelope: `pure`
    #     - namespace: "Policies::*"
    #       effect: [mutate.local]
    # ```
    #
    # This is the surface that pays on day one for a project that writes no RBS: one stanza bounds a whole
    # architectural layer. An entry attaches an envelope to every method of every class it selects and
    # **distributes exactly as a class-level annotation does** — reopenings and synthesised `attr_*` /
    # `define_method` members included, never subclasses (a subclass matches only if it matches on its own
    # account).
    #
    # ## Selection
    #
    # - `match:` selects by the class's **defining file**. A class matches when *any* file that defines a
    #   method of it matches the glob — a class opened in `app/presenters/user.rb` and reopened in
    #   `lib/patch.rb` is a presenter. `File.fnmatch?` with `FNM_PATHNAME`, project-relative, so `**` is
    #   the only way across a directory boundary: the `unused --entry-point` and
    #   `effects.snapshot.reach:` semantics, spelled once ({.path_match?}).
    # - `namespace:` selects by the class's **fully-qualified name**, segment by segment ({.namespace_match?}).
    #
    # ## Precedence
    #
    # Nearest wins, and configuration is the furthest thing from the method:
    #
    #     per-method annotation  >  class-level annotation  >  config entry
    #
    # Among config entries, the **first** matching entry in file order wins — a list is read top to
    # bottom, and a later entry never silently overrides one an author put above it. There is no merging:
    # one method has at most one envelope, from exactly one source.
    module ConfigEnvelopes
      # What `location` carries for a configured envelope. Not a `path:line` — the loader cannot say which
      # line the entry was written on — so it names the key path instead, which is what a reader greps for.
      CONFIG_PATH = ".rigor.yml"

      NO_ENVELOPES = {}.freeze
      private_constant :NO_ENVELOPES

      # One entry, resolved against the vocabulary.
      #
      # `bound` is {LabelSet::TOP} when some member of `effect:` is unrecognised — the fail-open rule, the
      # same degradation an annotation carrying an unknown label takes — and `unknown_labels` is what
      # `effect.unknown-label` reports off.
      Entry = Data.define(:index, :match, :namespace, :bound, :labels, :unknown_labels) do
        # `.rigor.yml effects.envelopes[2]` — how the `effect.envelope-exceeded` message names the source.
        def location = "#{CONFIG_PATH} effects.envelopes[#{index}]"

        # The bound quoted back the way the author wrote it, in the config's own spelling.
        def spelling = "effect: [#{labels.join(', ')}]"

        def top? = bound.top?
      end

      module_function

      # Resolves `Configuration#effects_envelopes` against a registry.
      #
      # @param entries [Array<Hash>] the loaded, shape-validated entries
      # @param registry [Registry] the vocabulary, project extensions included
      def build(entries:, registry:)
        entries.each_with_index.map do |entry, index|
          labels = Array(entry["effect"]).map(&:to_s)
          unknown = labels.reject { |label| registry.known?(label) }
          Entry.new(
            index: index, match: entry["match"], namespace: entry["namespace"],
            bound: unknown.empty? ? LabelSet.new(labels) : LabelSet::TOP,
            labels: labels.freeze, unknown_labels: unknown.freeze
          )
        end.freeze
      end

      # The class-level envelopes the entries put on a project.
      #
      # @param class_names [Enumerable<String>] every class the run collected units for
      # @param sources [Hash{String => Array<String>}] `Runner#effect_sources` — `{method key => [path]}`
      # @param project_root [String] what `sources` paths are relativised against
      # @return [Hash{String => Envelope}] one envelope per selected class, keyed by class name
      def for_classes(entries:, class_names:, sources: {}, project_root: Dir.pwd)
        return NO_ENVELOPES if entries.empty?

        files = files_by_class(sources, project_root)
        class_names.each_with_object({}) do |class_name, out|
          entry = entries.find { |candidate| selects?(candidate, class_name, files[class_name]) }
          next if entry.nil?

          out[class_name] = envelope_for(entry, class_name)
        end
      end

      # The {Envelope} an entry puts on one class. Public because {EnvelopeIndex} resolves the same
      # entries per *call site* rather than per project class ({.for_classes}'s shape), and the two
      # must build the identical value: a bound that read differently at a call site and at the `def`
      # would make the `≤` lane disagree with the check that enforces it.
      def envelope_for(entry, class_name)
        Envelope.build(
          owner_key: class_name, bound: entry.bound, source: Envelope::CONFIG_SOURCE,
          location: entry.location, spelling: entry.spelling,
          unknown_labels: entry.unknown_labels, declared_labels: entry.labels
        )
      end

      def selects?(entry, class_name, paths)
        return namespace_match?(entry.namespace, class_name) if entry.namespace

        Array(paths).any? { |path| path_match?(entry.match, path) }
      end

      # `File.fnmatch?` with `FNM_PATHNAME` over a project-relative path — the ADR-28 `path_glob` shape
      # and the `unused --entry-point` one. `FNM_PATHNAME` is what makes `app/*/x.rb` stop at one
      # directory and `**` the only way past it.
      def path_match?(glob, path)
        File.fnmatch?(glob, path, File::FNM_PATHNAME)
      end

      # A constant-path glob, matched **segment by segment** over the `::`-separated FQN:
      #
      # - a literal segment matches itself, and `*` inside one matches any run of characters *within* that
      #   segment (`Api::V*` matches `Api::V2`);
      # - `*` alone matches exactly one segment — `Presenters::*` matches `Presenters::User` and NOT
      #   `Presenters::Admin::User`, nor bare `Presenters`;
      # - `**` matches one or more consecutive segments — `Presenters::**` matches both `Presenters::User`
      #   and `Presenters::Admin::User`, and still not bare `Presenters`.
      #
      # Deliberately not `File.fnmatch` over a `/`-substituted name: the semantics above are the ones the
      # documentation states, and borrowing a path matcher would make them depend on how one library
      # happens to treat a trailing `**`.
      def namespace_match?(glob, class_name)
        match_segments?(glob.to_s.split("::"), class_name.to_s.split("::"))
      end

      def match_segments?(pattern, name)
        return name.empty? if pattern.empty?

        head, *rest = pattern
        return match_deep?(rest, name) if head == "**"
        return false if name.empty?
        return false unless File.fnmatch?(head, name.first)

        match_segments?(rest, name.drop(1))
      end

      # `**` consumes at least one segment, then the remaining pattern must match what is left. Bounded by
      # the name's own depth, so the recursion is a handful of frames on any real constant path.
      def match_deep?(rest, name)
        (1..name.length).any? { |taken| match_segments?(rest, name.drop(taken)) }
      end

      # `{class name => [project-relative path]}`, from the per-unit source table. Sorted and de-duplicated
      # so a glob decision does not depend on Hash order.
      def files_by_class(sources, project_root)
        root = "#{File.absolute_path(project_root.to_s).chomp('/')}/"
        sources.each_with_object({}) do |(key, paths), out|
          owner = MethodKey.owner(key)
          next if owner.nil?

          bucket = (out[owner] ||= [])
          Array(paths).each { |path| bucket << relativize(path, root) }
        end.each_value(&:uniq!)
      end

      def relativize(path, root)
        absolute = File.absolute_path(path.to_s)
        absolute.start_with?(root) ? absolute[root.length..] : path.to_s
      end

      private_class_method :selects?, :match_segments?, :match_deep?, :files_by_class, :relativize
    end
  end
end
