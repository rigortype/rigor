# frozen_string_literal: true

# Conventional Rails base controller. Discovered by
# rigor-actionpack's controller index so subclasses' Phase 2
# filter chains can reference inherited methods (one level of
# inheritance is walked).

class ApplicationController
  def authenticate_admin!
    # Inherited filter — UsersController would resolve
    # `before_action :authenticate_admin!` against this method.
  end
end
