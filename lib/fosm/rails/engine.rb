# Legacy shim — the real engine is Fosm::Engine defined in lib/fosm/engine.rb
require_relative "../engine"

module Fosm
  module Rails
    # Kept for backward compatibility. Aliases the real engine.
    Engine = Fosm::Engine
  end
end
