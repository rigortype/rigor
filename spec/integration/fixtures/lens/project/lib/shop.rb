# rbs_inline: enabled

# A shop.
class Shop
  LIMIT = 10

  # Documentation prose for label.
  #: (Integer n) -> String
  def label(n) = n.to_s

  # @rbs num: Float
  def scale(num) = num * 2

  def total = Order.new.amount

  def fetch(id) = id

  attr_reader :name, :code #: String

  def self.build = new

  attr_accessor :price #: Integer

  class << self
    def registry = {}
  end

  alias_method :title, :label

  private

  def secret = 1
end
