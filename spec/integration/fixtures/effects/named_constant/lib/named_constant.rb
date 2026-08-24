# frozen_string_literal: true

require "net/imap"

# A catalogued class the bundled rbs ships no signature for (#463). The constant therefore types
# `Dynamic`, and the only thing naming the class is the syntax the author wrote.
module NamedConstant
  class Written
    def connect
      Net::IMAP.new("host", port: 993, ssl: true)
    end
  end

  # The control the posture rule exists for: an unqualified call spells `Kernel#name`, and `Kernel`'s
  # instance posture is the whole outside world. Letting it answer would colour every call in every
  # project body.
  class Implicit
    def run
      helper
    end

    def helper
      1
    end
  end

  # The other control: a deferred selector's own taint is the more specific reading, and a named
  # constant must not talk it out of that.
  class Deferred
    def run
      Net::IMAP.send(:new, "host")
    end
  end
end
