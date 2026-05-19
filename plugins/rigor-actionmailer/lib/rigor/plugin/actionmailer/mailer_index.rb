# frozen_string_literal: true

module Rigor
  module Plugin
    class Actionmailer < Rigor::Plugin::Base
      # Frozen catalogue of discovered Mailer classes, each
      # carrying:
      #
      # - the action methods it defines (arity envelope per
      #   action; same shape as `rigor-activejob`'s
      #   `JobIndex::Entry`)
      # - the source file path the class was declared in
      #   (used to anchor missing-view diagnostics on the
      #   mailer file)
      # - the list of `(action, location)` pairs whose view
      #   templates are missing from `app/views/`
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

        ClassEntry = Data.define(:class_name, :file_path, :actions, :missing_views) do
          def find_action(method_name)
            actions[method_name.to_sym]
          end
        end

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.to_h { |entry| [entry.class_name, entry] }.freeze
          freeze
        end

        # @return [ClassEntry, nil]
        def find(class_name)
          @by_name[class_name.to_s]
        end

        def known?(class_name)
          @by_name.key?(class_name.to_s)
        end

        # @param file_path [String] absolute path of a mailer
        #   file (canonicalised — see plugin entry's
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
      end
    end
  end
end
