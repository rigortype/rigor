# frozen_string_literal: true

class ApplicationPolicy # rubocop:disable Lint/EmptyClass
  # Stand-in base class so this file parses standalone.
end

class CommentPolicy < ApplicationPolicy
  def edit?
    true
  end

  def reply?
    true
  end
end
