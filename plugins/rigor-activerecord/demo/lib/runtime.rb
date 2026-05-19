# frozen_string_literal: true

# Stand-in runtime so the demo files run under MRI without
# requiring Rails. Real Rails apps would `require "active_record"`
# instead. The plugin analyses the source — it does NOT need
# ActiveRecord loaded at lint time.

class ApplicationRecord
  def self.find(*) = new
  def self.find_by(**) = new
  def self.where(*, **) = []
  def self.all = []
end
