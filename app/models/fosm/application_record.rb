module Fosm
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # Only create a dedicated connection pool when the host app has explicitly
    # declared a "fosm" database role in database.yml.
    #
    # The previous guard — find_db_config("primary") — fired for every Rails app
    # because "primary" is the default role name Rails assigns to every
    # database.yml entry. This created a redundant second pool targeting the same
    # database, which caused a structural cross-pool deadlock with ActiveStorage
    # (and any ActiveRecord::Base.transaction block that touched Fosm::* models)
    # on all single-database setups (SQLite, PostgreSQL, MySQL):
    #
    #   Fosm pool  →  BEGIN TRANSACTION  (holds write lock)
    #   App pool   →  BEGIN TRANSACTION  (needs write lock — blocked)
    #   Fosm pool  →  after_save triggers ActiveStorage write via App pool
    #   → DEADLOCK: each pool waiting for the other to release the write lock
    #
    # The fix: only split into a separate pool when the host app opts in by
    # declaring a "fosm" role in database.yml. Single-database apps share the
    # default ActiveRecord::Base pool and are not affected.
    #
    # To use a dedicated FOSM database, add to database.yml:
    #
    #   fosm:
    #     <<: *default
    #     database: db/fosm.sqlite3   # or a separate PostgreSQL/MySQL URL
    #
    connects_to database: { writing: :fosm } if ActiveRecord::Base.configurations.find_db_config("fosm")
  end
end
