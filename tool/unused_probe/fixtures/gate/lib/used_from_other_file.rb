# frozen_string_literal: true

# Case 1: declared here, referenced from consumer.rb by its bare name.
class UsedFromOtherFile
  def hello = "hi"
end
