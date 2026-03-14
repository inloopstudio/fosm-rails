module Fosm
  class ApplicationJob < ActiveJob::Base
    # The FOSM engine uses the host app's ActiveJob queue adapter.
    # Override queue_name in subclasses if needed.
  end
end
