# frozen_string_literal: true

# Sample job — rigor-activejob discovers this class because
# its direct superclass is `ApplicationJob` (one of the
# default `job_base_classes`). The discoverer reads the
# `#perform` method's parameter list to compute arity.

class ApplicationJob
  # Stand-in base class so `ruby app/jobs/welcome_email_job.rb`
  # parses standalone (without ActiveJob loaded). rigor-activejob
  # doesn't care whether the class is declared here or anywhere
  # else — it only matches by name against `job_base_classes`.
  def self.perform_later(*); end
  def self.perform_now(*); end
end

class WelcomeEmailJob < ApplicationJob
  def perform(user_id, locale = "en")
    # Body is not analysed by rigor-activejob — only the
    # signature.
    [user_id, locale]
  end
end

class ReportJob < ApplicationJob
  def perform(*report_ids)
    # `*report_ids` makes the upper bound unbounded
    # (`0+` arity). Calling `ReportJob.perform_later`
    # with no arguments is OK.
    report_ids
  end
end
