# Legacy entry point — kept for backward compatibility.
# The primary entry point is lib/fosm-rails.rb.
require "fosm-rails"

module Fosm
  module Rails
    # Shim module so any code that references Fosm::Rails still loads cleanly.
  end
end
