require "rails/generators"
require "rails/generators/active_record"

module Fosm
  module Generators
    class AppGenerator < ::Rails::Generators::NamedBase
      include ::Rails::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      class_option :fields, type: :array, default: [], banner: "field:type field:type",
                             desc: "List of fields for the FOSM record table"
      class_option :states, type: :string, default: "draft,active,completed",
                             desc: "Comma-separated list of states (first is initial)"
      class_option :access, type: :string, default: "",
                             desc: "Authorization method (e.g. authenticate_user!, require_facilitator!)"

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_model_file
        template "model.rb.tt", "app/models/fosm/#{file_name}.rb"
      end

      def create_controller_file
        template "controller.rb.tt", "app/controllers/fosm/#{file_name}_controller.rb"
      end

      def create_agent_file
        template "agent.rb.tt", "app/agents/fosm/#{file_name}_agent.rb"
      end

      def create_view_files
        template "views/index.html.erb.tt", "app/views/fosm/#{file_name}/index.html.erb"
        template "views/show.html.erb.tt",  "app/views/fosm/#{file_name}/show.html.erb"
        template "views/new.html.erb.tt",   "app/views/fosm/#{file_name}/new.html.erb"
        template "views/_form.html.erb.tt", "app/views/fosm/#{file_name}/_form.html.erb"
      end

      def create_migration_file
        migration_template "migration.rb.tt", "db/migrate/create_fosm_#{table_name}.rb"
      end

      def inject_agent_instructions
        claude_md = ::Rails.root.join("CLAUDE.md")
        sentinel  = "<!-- fosm:agent-instructions -->"

        if File.exist?(claude_md) && File.read(claude_md).include?(sentinel)
          say_status :skip, "CLAUDE.md already has FOSM agent instructions", :yellow
          return
        end

        gem_root = Fosm::Engine.root.to_s
        agents_md_path = File.join(gem_root, "AGENTS.md")

        section = <<~MARKDOWN

          #{sentinel}
          ## FOSM (fosm-rails)

          This project uses `fosm-rails` — a Finite Object State Machine engine.
          When the user asks to build, extend, or modify features involving state machines,
          lifecycles, FOSM, or any code under `app/models/fosm/`, `app/controllers/fosm/`,
          or `app/agents/fosm/`, you **must** read and follow the instructions in:

          `#{agents_md_path}`
        MARKDOWN

        if File.exist?(claude_md)
          append_to_file claude_md, section
        else
          create_file claude_md, section.lstrip
        end
      end

      def update_routes
        routes_file = ::Rails.root.join("config/routes/fosm.rb")

        route_entry = <<~RUBY
          scope module: "fosm", path: "/fosm/apps", as: :fosm do
            resources :#{plural_name}, controller: "#{file_name}" do
              member { post :fire_event }
            end
          end
        RUBY

        if File.exist?(routes_file)
          append_to_file routes_file, "\n#{route_entry}"
        else
          create_file routes_file, route_entry
          # Also ensure main routes.rb draws from fosm.rb
          main_routes = ::Rails.root.join("config/routes.rb")
          unless File.read(main_routes).include?("draw :fosm")
            inject_into_file main_routes, "\n  draw :fosm", after: "Rails.application.routes.draw do"
          end
        end
      end

      private

      def states_list
        options[:states].split(",").map(&:strip)
      end

      def initial_state
        states_list.first
      end

      def table_name
        file_name.pluralize
      end

      def plural_name
        name.underscore.pluralize
      end

      def access_method
        # Strip shell-escaped ! (zsh escapes ! in double-quoted strings as \!)
        options[:access].gsub("\\!", "!")
      end

      def fields_for_migration
        # Handle both styles:
        #   --fields name:string amount:decimal   (array, multiple args)
        #   --fields "name:string amount:decimal" (single quoted string)
        raw_fields = options[:fields].join(" ").split(/[\s,]+/).reject(&:blank?)
        raw_fields.map do |field|
          parts = field.split(":")
          { name: parts[0].strip, type: (parts[1] || "string").strip }
        end
      end

      def fields_for_permit
        fields_for_migration.map { |f| f[:name].to_sym }.inspect
      end
    end
  end
end
