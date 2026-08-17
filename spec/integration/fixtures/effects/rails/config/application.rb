# The one line the effect layer reads out of this file: the queue adapter, which decides whether an
# enqueue is a database write, a Redis round trip, or nothing at all (ADR-103 WD10).
module Fixture
  class Application
    def self.configure(config)
      config.active_job.queue_adapter = :solid_queue
    end
  end
end
