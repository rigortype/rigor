# frozen_string_literal: true

# Sample Pundit policy — rigor-pundit discovers this class
# because its direct superclass is `ApplicationPolicy` (the
# default `policy_base_classes`). The discoverer collects
# every instance-side `def name?` predicate method.

class ApplicationPolicy # rubocop:disable Lint/EmptyClass
  # Stand-in base class so this file parses standalone.
  # rigor-pundit doesn't care whether the base class is
  # declared here or anywhere else — it only matches by
  # name against `policy_base_classes`.
end

class PostPolicy < ApplicationPolicy
  def show?
    true
  end

  def update?
    true
  end

  def destroy?
    false
  end
end
