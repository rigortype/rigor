# frozen_string_literal: true

require_relative "sig_gen/classification"
require_relative "sig_gen/method_candidate"
require_relative "sig_gen/observed_call"
require_relative "sig_gen/type_elaborator"
require_relative "sig_gen/observation_collector"
require_relative "sig_gen/generator"
require_relative "sig_gen/renderer"
require_relative "sig_gen/path_mapper"
require_relative "sig_gen/write_result"
require_relative "sig_gen/writer"

module Rigor
  # Namespace for the RBS signature generator that powers
  # `rigor sig-gen` (ADR-14).
  #
  # The generator emits RBS from Rigor's inference results so
  # users close RBS coverage gaps without freehand authorship.
  # See `docs/adr/14-rbs-sig-generation.md` for the design
  # rationale and the slicing plan.
  module SigGen
  end
end
