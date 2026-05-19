# frozen_string_literal: true

module Rigor
  module Plugin
    class Pundit < Rigor::Plugin::Base
      # Frozen catalogue of discovered Pundit policy classes
      # keyed by policy class name (e.g. `"PostPolicy"`).
      # Each entry tracks the set of predicate methods
      # defined on the policy (instance-side `def name?`)
      # plus the source file path.
      #
      # The analyzer maps a record's inferred type
      # (`Nominal[Post]`) to the policy class name
      # (`"PostPolicy"`) and looks up the predicate.
      class PolicyIndex
        Entry = Data.define(:policy_class_name, :file_path, :predicate_methods) do
          def includes_method?(method_name)
            predicate_methods.include?(normalize(method_name))
          end

          def known_methods
            predicate_methods.to_a.sort
          end

          # Normalises an action symbol / string by ensuring
          # a trailing `?`. `:update` and `:update?` both
          # resolve to `update?`.
          def normalize(name)
            string = name.to_s
            string.end_with?("?") ? string.to_sym : :"#{string}?"
          end
        end

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.to_h { |entry| [entry.policy_class_name, entry] }.freeze
          freeze
        end

        # @return [Entry, nil]
        def find(policy_class_name)
          @by_name[policy_class_name.to_s]
        end

        def known?(policy_class_name)
          @by_name.key?(policy_class_name.to_s)
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
