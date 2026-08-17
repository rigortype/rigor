# frozen_string_literal: true

module Rigor
  module Plugin
    # One row of a plugin's `effect_attributions:` — "a call to this receiver's method contributes these
    # effect labels" (ADR-103 WD6 / WD10; design note § 6.6; the contract is
    # `docs/internal-spec/plugin.md` § Effect contributions).
    #
    # A framework method has no body Rigor reads, so someone must colour it. Three channels can, in
    # descending order of preference:
    #
    # 1. a `%a{rigor:v1:effect …}` annotation in the plugin's own `signature_paths:` RBS — tier 1, read
    #    through {Rigor::Effects::EnvelopeIndex}'s accepted stratum, and the right channel whenever the
    #    plugin already ships a signature for the method;
    # 2. this field, for the methods RBS cannot name per app — association readers, `find_by_*`, scopes —
    #    and for classes the plugin ships no RBS for at all;
    # 3. the project's own `effects.attribution:` table, which is the user's answer for everything left.
    #
    # ## The receiver
    #
    # `receiver` is spelled one of two ways, and the spelling picks the matching rule:
    #
    # - a **class name** (`"ActiveRecord::Base"`, `"I18n"`) matches the class the call's receiver
    #   projects to, **through the project's inheritance chain**: an `ActiveRecord::Base` row applies to
    #   `User.find` because the project declares `User < ApplicationRecord < ActiveRecord::Base`. This is
    #   the difference from a catalogue row, which matches its exact owner and nothing else — Ruby's core
    #   classes are leaves in practice and a framework's base class never is.
    # - a **receiver path** (`"Rails.cache"`, `"Time.zone"`, `"Rails.application.credentials"`) matches
    #   the receiver *expression* as the syntax spells it. `Rails.cache.read` has no receiver class the
    #   typer can name — `Rails.cache` is a call, and its return type is adapter-dependent by design —
    #   so the only honest handle on it is the path that was written.
    # - a **self path** (`"self.session"`, `"self.flash.now"`, `"self.cookies.encrypted"`) is the same
    #   thing rooted at implicit self, and is what a Rails controller's accessors actually look like:
    #   `session[:user_id] = id` is `[]=` on the result of a receiver-less `session`. A self-path row MUST
    #   name a `within:` class, because a receiver-less `session` in some other project class is a
    #   different `session` — the row applies only inside a class whose project ancestry reaches `within`.
    #
    # `on_result: true` shifts a class-name row one link outwards: it matches a call on **what a call to
    # that class returned**. `UserMailer.welcome(u).deliver_now` and `WelcomeJob.set(wait: 1.hour)
    # .perform_later` are the two idioms that need it — the object in the middle is a lazy
    # `MessageDelivery` / `ConfiguredJob` whose type nothing in the project declares, while the class that
    # produced it is written right there in the source. Without it the send and the enqueue, the two calls
    # a reviewer most wants coloured, would go unattributed in the spelling Rails actually uses.
    #
    # ## Discharge
    #
    # `discharge: true` says the label is derived from the framework's own semantics rather than guessed,
    # so the site is exhaustive rather than tainted. ADR-103 WD6 grants that only to a **first-party
    # bundled** plugin ({FirstParty}), gated by `make check-plugins`; a third-party plugin's `true` is
    # ignored with a load-time warning and the row behaves like the project's `effects.attribution:`
    # table — declared, and carrying a `plugin-attribution` taint.
    #
    # Either way the labels land in the **declared** lane, never the proven one. A discharging row is a
    # trusted claim, exactly like an accepted signature's `%a{…}`: "this is what it does", not "the
    # analyzer read the body and saw this".
    class EffectAttribution
      # A receiver spelled as a `Constant::Path` — the class-name form. Anything else with a `.` in it is
      # read as a receiver path.
      CLASS_NAME = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

      # A receiver path: a constant head followed by one or more sends (`Rails.cache`,
      # `Rails.application.credentials`).
      RECEIVER_PATH = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*(\.[a-z_][A-Za-z0-9_]*)+\z/

      # A self path: implicit self followed by one or more receiver-less sends (`self.flash.now`).
      SELF_PATH = /\Aself(\.[a-z_][A-Za-z0-9_]*)+\z/

      # What a self path is rooted at, once the `self.` head is stripped.
      SELF_HEAD = "self"

      attr_reader :receiver, :method, :singleton, :labels, :narrow, :discharge, :within, :on_result,
                  :taint, :why

      # The taint causes a plugin row may name. A closed subset of
      # {Rigor::Effects::TaintCause::ALL}: a plugin may say "and there is more here I cannot see", but
      # only for the two reasons a framework model can honestly have — a template it does not read, and a
      # callable whose body is supplied by the application.
      TAINT_CAUSES = %w[template-not-analysed opaque-callable].freeze

      # @param receiver [String] a class name or a receiver path (see above)
      # @param method [Symbol, String] the selector this row colours
      # @param singleton [Boolean] whether the row is `Receiver.method` rather than `Receiver#method`.
      #   Meaningless — and ignored — for a receiver path, whose head already fixes the receiver object.
      # @param labels [Array<String>] the effect labels the call contributes
      # @param narrow [String, nil] a {Rigor::Effects::Narrowing} handler name, when the call's own
      #   argument literals settle a question the row cannot (`connection.execute("SELECT …")`)
      # @param discharge [Boolean] see above; honoured only for a first-party bundled plugin
      # @param why [String] the audit justification, required exactly as `data/effects/core.yml` requires
      #   one of every row: a label with no stated reason is a claim nobody can review.
      def initialize(receiver:, method:, labels:, why:, singleton: false, narrow: nil, discharge: false, # rubocop:disable Metrics/ParameterLists
                     within: nil, on_result: false, taint: nil)
        @receiver = validate_receiver!(receiver)
        @method = method.to_sym
        @singleton = singleton ? true : false
        @labels = normalize_labels(labels)
        @narrow = narrow.nil? ? nil : narrow.to_s.dup.freeze
        @discharge = discharge ? true : false
        @within = validate_within!(within)
        @on_result = on_result ? true : false
        validate_on_result!
        @taint = validate_taint!(taint)
        @why = validate_why!(why)
        freeze
      end

      # Whether {#receiver} is a receiver path (`Rails.cache`) rather than a class name or a self path.
      def receiver_path?
        @receiver.include?(".") && !self_path?
      end

      # Whether {#receiver} is a self path (`self.flash.now`).
      def self_path?
        @receiver.start_with?("#{SELF_HEAD}.")
      end

      # The key an origin and a report spell this row as.
      def key
        return "#{@receiver}.#{@method}" if receiver_path? || self_path?
        return "#{@receiver}()##{@method}" if @on_result

        "#{@receiver}#{@singleton ? '.' : '#'}#{@method}"
      end

      def to_h
        {
          "receiver" => @receiver, "method" => @method.to_s, "singleton" => @singleton,
          "labels" => @labels, "narrow" => @narrow, "discharge" => @discharge, "within" => @within,
          "on_result" => @on_result, "taint" => @taint
        }
      end

      def ==(other)
        other.is_a?(EffectAttribution) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      private

      def validate_receiver!(receiver)
        value = receiver.to_s
        unless CLASS_NAME.match?(value) || RECEIVER_PATH.match?(value) || SELF_PATH.match?(value)
          raise ArgumentError,
                "effect attribution receiver must be a class name, a receiver path or a self path, " \
                "got #{receiver.inspect}"
        end

        value.dup.freeze
      end

      # A self path with no `within:` would colour a receiver-less `session` in any project class at all.
      def validate_within!(within)
        if within.nil?
          raise ArgumentError, "effect attribution #{key} is a self path and must name a `within:` class" if self_path?

          return nil
        end

        value = within.to_s
        raise ArgumentError, "effect attribution `within:` must be a class name, got #{within.inspect}" unless
          CLASS_NAME.match?(value)

        value.dup.freeze
      end

      def normalize_labels(labels)
        list = Array(labels).map { |label| label.to_s.dup.freeze }
        raise ArgumentError, "effect attribution for #{@receiver} must declare at least one label" if list.empty?

        list.uniq.sort.freeze
      end

      # `on_result:` shifts the match one link outwards, which only a class-name row can do: a receiver
      # path already names the object, and a self path already names the frame.
      def validate_on_result!
        return unless @on_result
        return unless receiver_path? || self_path?

        raise ArgumentError, "effect attribution #{key} may not combine `on_result:` with a path receiver"
      end

      # A row may state a bound AND say the bound is not the whole story. `render` is the case that needs
      # it: what the controller does IS `mutate.self` + `rails.response.write`, and what the TEMPLATE does
      # is unknown until views become effect units (ADR-103 WD11). Reporting only the first would be a
      # summary that reads exhaustive and is not.
      def validate_taint!(taint)
        return nil if taint.nil?

        value = taint.to_s
        return value.dup.freeze if TAINT_CAUSES.include?(value)

        raise ArgumentError,
              "effect attribution #{key} may only taint with one of #{TAINT_CAUSES.inspect}, " \
              "got #{taint.inspect}"
      end

      def validate_why!(why)
        value = why.to_s
        raise ArgumentError, "effect attribution #{key} needs a `why:` justification" if value.empty?

        value.dup.freeze
      end
    end
  end
end
