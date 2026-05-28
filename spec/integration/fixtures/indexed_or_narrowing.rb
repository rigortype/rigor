require "rigor/testing"
include Rigor::Testing

# `params[:f] ||= []` records a per-slot narrowing so the next
# read at `params[:f]` is known non-nil. Without this, the
# empty `HashShape{}` lookup folds to `Constant[nil]` and the
# `<<` below would dispatch on nil.
#
# Redmine 6.1.2 `app/models/query.rb#as_params` (the worked site
# from the ROADMAP § Future cycles entry) repeats this idiom six
# times across `params[:f]` / `params[:op]` / `params[:v]`.
params = {}
params[:f] ||= []
params[:f] << :status

# The chained `params[:op][field] = ...` form: outer `params[:op]`
# is the receiver of an inner `[]=`, so it MUST type as non-nil.
params[:op] ||= {}
params[:op][:status] = "="

# String keys work too — same stable-literal recognition.
params["v"] ||= {}
params["v"]["status"] = ["open"]

# Ivar receivers: the same narrowing covers `@params[:k] ||=`.
class Holder
  def store!
    @bag = {}
    @bag[:items] ||= []
    @bag[:items] << :first
  end
end

# Integer keys also count as stable literals.
indexed = {}
indexed[0] ||= []
indexed[0] << :leaf
