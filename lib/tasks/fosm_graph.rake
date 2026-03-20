# frozen_string_literal: true

require "rake"

namespace :fosm do
  namespace :graph do
    desc "Generate state machine graph for a FOSM model (e.g., rake fosm:graph:generate MODEL=Invoice)"
    task generate: :environment do
      model_name = ENV["MODEL"]
      raise "Usage: rake fosm:graph:generate MODEL=Invoice" unless model_name

      model_class = "Fosm::#{model_name}".constantize rescue model_name.constantize
      raise "#{model_name} does not include Fosm::Lifecycle" unless model_class.respond_to?(:fosm_lifecycle)

      lifecycle = model_class.fosm_lifecycle
      output_dir = ENV["OUTPUT"] || Rails.root.join("app", "assets", "graphs")
      FileUtils.mkdir_p(output_dir)

      # Generate machine-level graph
      machine_data = {
        machine: model_class.name,
        states: lifecycle.states.map { |s| 
          { 
            name: s.name, 
            initial: s.initial?, 
            terminal: s.terminal? 
          } 
        },
        events: lifecycle.events.map { |e|
          {
            name: e.name,
            from: e.from_states,
            to: e.to_state,
            force: e.force?,
            guards: e.guards.map(&:name),
            side_effects: e.side_effects.map(&:name)
          }
        }
      }

      # Detect cross-machine connections by analyzing side effect names
      cross_connections = []
      lifecycle.events.each do |event|
        event.side_effects.each do |side_effect|
          name = side_effect.name.to_s
          # Convention: trigger_other_machine or activate_contract patterns
          if name.include?("_")
            parts = name.split("_")
            potential_targets = parts.select { |p| 
              # Look for capitalized words that match model names
              p.capitalize == p && Object.const_defined?("Fosm::#{p.capitalize}") rescue false
            }
            potential_targets.each do |target|
              cross_connections << {
                source: { machine: model_class.name, event: event.name },
                via: side_effect.name,
                target_machine: "Fosm::#{target.capitalize}"
              }
            end
          end
        end
      end

      machine_data[:cross_machine_connections] = cross_connections

      # Write machine graph
      machine_file = File.join(output_dir, "#{model_name.underscore}_graph.json")
      File.write(machine_file, JSON.pretty_generate(machine_data))
      puts "Generated: #{machine_file}"

      # Generate system-wide graph if requested
      if ENV["SYSTEM"]
        system_data = Fosm::Graph.system_graph
        system_file = File.join(output_dir, "fosm_system_graph.json")
        File.write(system_file, JSON.pretty_generate(system_data))
        puts "Generated: #{system_file}"
      end
    end

    desc "Generate graphs for all FOSM models"
    task all: :environment do
      Fosm::Registry.each do |slug, model_class|
        ENV["MODEL"] = model_class.name.demodulize
        Rake::Task["fosm:graph:generate"].invoke
        Rake::Task["fosm:graph:generate"].reenable
      end
    end
  end
end

module Fosm
  class Graph
    # Generate system-wide dependency graph
    def self.system_graph
      machines = {}
      connections = []

      Fosm::Registry.each do |slug, model_class|
        next unless model_class.respond_to?(:fosm_lifecycle)
        lifecycle = model_class.fosm_lifecycle

        machines[model_class.name] = {
          states: lifecycle.states.count,
          events: lifecycle.events.count,
          terminal_states: lifecycle.states.select(&:terminal?).map(&:name)
        }

        lifecycle.events.each do |event|
          event.side_effects.each do |side_effect|
            connections << {
              from: model_class.name,
              to: infer_target_from_side_effect(side_effect),
              via: side_effect.name,
              event: event.name
            } if infer_target_from_side_effect(side_effect)
          end
        end
      end

      {
        machines: machines,
        connections: connections.compact,
        generated_at: Time.current.iso8601
      }
    end

    def self.infer_target_from_side_effect(side_effect)
      name = side_effect.name.to_s
      # Common patterns: activate_contract, notify_user, create_payment
      targets = %w[Contract Invoice User Payment Order Shipment].select do |model|
        name.downcase.include?(model.downcase)
      end
      targets.first ? "Fosm::#{targets.first}" : nil
    end
  end
end
