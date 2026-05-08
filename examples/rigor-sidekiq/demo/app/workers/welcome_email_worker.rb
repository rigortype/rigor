# frozen_string_literal: true

# Sample workers — rigor-sidekiq discovers these classes
# because each one `include`s `Sidekiq::Job` (one of the
# default `worker_marker_modules`). The discoverer reads
# the `#perform` method's parameter list to compute arity.

module Sidekiq
  module Job
    # Stand-in marker module so this file parses standalone
    # (without Sidekiq loaded). rigor-sidekiq doesn't care
    # whether the module is declared here or anywhere else
    # — it only matches by name against
    # `worker_marker_modules`.
    def self.perform_async(*); end
    def self.perform_in(*); end
    def self.perform_at(*); end
    def self.perform_inline(*); end
  end
end

class WelcomeEmailWorker
  include Sidekiq::Job

  def perform(user_id, locale = "en")
    # Body is not analysed by rigor-sidekiq — only the
    # signature.
    [user_id, locale]
  end
end

class ReportWorker
  include Sidekiq::Job

  def perform(*report_ids)
    # `*report_ids` makes the upper bound unbounded
    # (`0+` arity). Calling `ReportWorker.perform_async`
    # with no arguments is OK.
    report_ids
  end
end
