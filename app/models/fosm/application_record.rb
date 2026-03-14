module Fosm
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
    connects_to database: { writing: :primary } if ActiveRecord::Base.configurations.find_db_config("primary")
  end
end
