# frozen_string_literal: true

module UnknownLabels
  class Signals
    def near_miss
      puts("near miss")
    end

    def known_sibling
      puts("known sibling")
    end

    def dotted
      puts("dotted")
    end

    def lone_word
      puts("lone word")
    end
  end
end
