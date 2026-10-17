# frozen_string_literal: true

module Rigor
  module Inference
    # Issue #1572 — the singleton typing site's external-ahead decline. That site still answers from
    # {Scope#singleton_def_through_ancestors}, which passes the chain's external entries over, so `extend M; extend
    # Enumerable` typed `C.to_a` from `M#to_a` although Ruby calls `Enumerable#to_a` (`C.singleton_class.ancestors`
    # starts `[#<Class:C>, Enumerable, M]`). The instance typing site reads `DefinerResolution`, which already
    # declines there.
    #
    # {.withhold?} is true when the read must withhold (the call types `Dynamic`): the singleton chain holds no
    # project entry that writes the name; the reader's `owner` has no project entry on it; or an external entry ahead
    # of the later of the two may answer first, because RBS does not know it or declares the name in it (the test
    # `DefinerResolution` applies, `ResolutionChain::Relevance.external_lacks_on?`). The later of the two, because
    # where the chain does not stand the reader answers master's owner. An entry writes the name with its own `def`,
    # never a copy the extends fold put on a class object (`RefinedDispatch::ClassObject.fold_copy?`, which also
    # matches a copy by location where the two tables came from two parses of the file), so a folded `M#to_a`
    # answers at `M`'s own position.
    #
    # ADR-46: the search files the class edge of the root and of every project entry ahead of the definer, and each
    # tested external files the negative class edge on its spelling's last segment, as `DefinerResolution` does.
    module SingletonExternalAhead
      module_function

      def withhold?(scope, class_name, method_name, owner)
        chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
        definer = first_writer_index(scope, chain, method_name)
        return true if definer.nil?

        owner_index = chain.entries.index { |entry| !entry.external? && entry.name == owner.to_s }
        return true if owner_index.nil?

        external_ahead_may_answer?(scope, chain, method_name, [definer, owner_index].max)
      end

      def first_writer_index(scope, chain, method_name)
        index = -1
        chain.search(scope) do |entry|
          index += 1
          !entry.external? && writes_name?(scope, entry, method_name)
        end && index
      end

      def writes_name?(scope, entry, method_name)
        return !scope.user_def_for(entry.name, method_name).nil? unless entry.side == :singleton

        !scope.singleton_def_for(entry.name, method_name).nil? &&
          !RefinedDispatch::ClassObject.fold_copy?(scope, entry.name, method_name)
      end

      def external_ahead_may_answer?(scope, chain, method_name, stop)
        recording = Analysis::DependencyRecorder.active?
        chain.entries.first(stop).any? do |entry|
          next false unless entry.external?

          Analysis::DependencyRecorder.read_missing(:class, entry.raw.to_s.split("::").last) if recording
          !Scope::ResolutionChain::Relevance.external_lacks_on?(scope, entry.candidates, entry.side, method_name)
        end
      end

      private_class_method :first_writer_index, :writes_name?, :external_ahead_may_answer?
    end
  end
end
