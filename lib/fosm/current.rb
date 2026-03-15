module Fosm
  # Per-request cache for FOSM RBAC role lookups.
  #
  # Loads ALL role assignments for the current actor in ONE SQL query on first
  # access, then serves subsequent checks from an in-memory hash (O(1) lookup).
  # Resets automatically at the end of each request via ActiveSupport::CurrentAttributes.
  #
  # Cache structure:
  #   { "User:42" => { "Fosm::Invoice" => { nil => [:owner], "5" => [:approver] } } }
  #             ↑ actor key           ↑ type-level         ↑ record-level
  class Current < ActiveSupport::CurrentAttributes
    attribute :_access_cache

    # Retrieve cached roles for a given actor + model class + optional record ID.
    # Loads from DB on first call for this actor (one query per actor per request).
    #
    # @param actor       [Object]  an ActiveRecord user object with .class.name and .id
    # @param model_class [Class]   the FOSM model class (e.g. Fosm::Invoice)
    # @param record_id   [Integer, String, nil] specific record ID, or nil for type-level only
    # @return [Array<Symbol>] list of role names this actor has on the resource
    def self.roles_for(actor, model_class, record_id = nil)
      actor_key = cache_key(actor)

      unless _access_cache&.key?(actor_key)
        self._access_cache ||= {}
        self._access_cache[actor_key] = load_for_actor(actor)
      end

      actor_data  = _access_cache[actor_key]
      type_roles   = actor_data.dig(model_class.name, nil) || []
      record_roles = record_id ? (actor_data.dig(model_class.name, record_id.to_s) || []) : []
      (type_roles + record_roles).uniq
    end

    # Invalidate the cached roles for a specific actor (e.g., after granting a new role).
    def self.invalidate_for(actor)
      _access_cache&.delete(cache_key(actor))
    end

    private_class_method def self.cache_key(actor)
      "#{actor.class.name}:#{actor.respond_to?(:id) ? actor.id : actor.object_id}"
    end

    # Load all role assignments for the actor across ALL FOSM resource types.
    # Single SQL query, cached for the lifetime of the request.
    private_class_method def self.load_for_actor(actor)
      Fosm::RoleAssignment
        .where(user_type: actor.class.name, user_id: actor.id.to_s)
        .pluck(:resource_type, :resource_id, :role_name)
        .each_with_object({}) do |(rtype, rid, role), cache|
          cache[rtype] ||= {}
          (cache[rtype][rid] ||= []) << role.to_sym
        end
    end
  end
end
