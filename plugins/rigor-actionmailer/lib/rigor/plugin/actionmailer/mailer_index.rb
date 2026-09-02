# frozen_string_literal: true

module Rigor
  module Plugin
    class Actionmailer < Rigor::Plugin::Base
      # Frozen catalogue of discovered Mailer classes, each carrying:
      #
      # - the action methods it defines (arity envelope per action; same shape as `rigor-activejob`'s
      #   `JobIndex::Entry`)
      # - the source file path the class was declared in (used to anchor missing-view diagnostics on
      #   the mailer file)
      # - the list of `(action, location)` pairs whose view templates are missing from `app/views/`
      class MailerIndex
        ActionEntry = Data.define(:method_name, :min_arity, :max_arity, :def_line, :def_column) do
          def arity_label
            return "#{min_arity}+" if max_arity == Float::INFINITY
            return min_arity.to_s if min_arity == max_arity

            "#{min_arity}..#{max_arity}"
          end

          def accepts?(actual)
            actual.between?(min_arity, max_arity)
          end
        end

        ClassEntry = Data.define(:class_name, :file_path, :actions, :missing_views, :unresolved_includes) do
          def find_action(method_name)
            actions[method_name.to_sym]
          end

          # True when the mailer `include`s a module whose source we couldn't index (typically a
          # gem-shipped concern that defines additional mailer actions). Analyzer downgrades
          # `unknown-action` to silence in this case — the unresolved module may legitimately provide
          # the action.
          def unresolved_includes?
            !unresolved_includes.empty?
          end
        end

        attr_reader :entries

        # `entries` holds one row PER DECLARATION — a mailer declared in two files contributes two — because
        # {#find_by_file} anchors the `missing-view` diagnostics on the file each action's `def` lives in.
        # The by-name view a call site consults is the UNION of a class's declarations ({.merge_entry}): a
        # reopen ADDS actions rather than replacing the class, so keeping the last row alone reported
        # `unknown-action` on every action the other declaration spelled (#621).
        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.each_with_object({}) do |entry, acc|
            name = entry.class_name
            acc[name] = acc.key?(name) ? self.class.merge_entry(acc[name], entry) : entry
          end.freeze
          freeze
        end

        # Entries are keyed by the de-rooted constant path (`"UserMailer"`, `"Admin::UserMailer"` — never
        # `"::UserMailer"`; see {MailerDiscoverer}), while a QUERY may legitimately arrive rooted:
        # `::UserMailer.welcome(u)` renders its receiver as `"::UserMailer"`. The root marker is dropped
        # here, once, so no caller needs a `find(name) || find("::#{name}")` retry (#621).
        #
        # @return [ClassEntry, nil]
        def find(class_name)
          @by_name[strip_leading_namespace(class_name.to_s)]
        end

        def known?(class_name)
          @by_name.key?(strip_leading_namespace(class_name.to_s))
        end

        # @param file_path [String] absolute path of a mailer file (canonicalised — see plugin entry's
        #   `harvest`)
        # @return [ClassEntry, nil]
        def find_by_file(file_path)
          @entries.find { |entry| entry.file_path == file_path }
        end

        def empty?
          @entries.empty?
        end

        def size
          @entries.size
        end

        def names
          @by_name.keys
        end

        # Unions two declarations of the SAME mailer class. `base` is the earlier row, `addition` the later
        # one; Ruby's own semantics are additive, so nothing either declaration spelled is lost. Actions are
        # name-keyed (a redefinition in the later file wins, as it does at load time), `missing_views` and
        # `unresolved_includes` union, and `file_path` stays the earlier declaration's — the merged row is
        # only ever reached by name, never by {#find_by_file}, which reads the per-declaration `entries`.
        def self.merge_entry(base, addition)
          base.with(
            actions: base.actions.merge(addition.actions),
            missing_views: (base.missing_views | addition.missing_views).freeze,
            unresolved_includes: (base.unresolved_includes | addition.unresolved_includes).freeze
          )
        end

        # `::UserMailer` → `UserMailer`. The query-side half of the key contract — see {#find}.
        def self.strip_leading_namespace(name) = name.delete_prefix("::")

        private

        def strip_leading_namespace(name) = self.class.strip_leading_namespace(name)
      end
    end
  end
end
