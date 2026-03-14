# Legacy helper kept for backward compatibility.
# New code should use Fosm::ApplicationHelper directly.
require_relative "../application_helper"

module Fosm
  module Rails
    module ApplicationHelper
      include Fosm::ApplicationHelper
    end
  end
end
