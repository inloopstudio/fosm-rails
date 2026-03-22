require_relative "lib/fosm/version"

Gem::Specification.new do |spec|
  spec.name        = "fosm-rails"
  spec.version     = Fosm::VERSION
  spec.authors     = [ "Abhishek Parolkar" ]
  spec.email       = [ "abhishek@parolkar.com" ]
  spec.homepage    = "https://github.com/inloopstudio/fosm-rails"
  spec.summary     = "Finite Object State Machine for Rails — declarative lifecycles for business objects"
  spec.description = "FOSM gives your Rails models a formal, enforced lifecycle with states, events, guards, side-effects, and an AI agent interface. Business rules live in the model, not scattered across callbacks."
  spec.license     = "FSL-1.1-Apache-2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/inloopstudio/fosm-rails"
  spec.metadata["changelog_uri"]   = "https://github.com/inloopstudio/fosm-rails/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "LICENSE", "Rakefile", "README.md", "AGENTS.md"]
  end

  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "rails",    ">= 8.1"
  spec.add_dependency "gemlings", ">= 0.3"
end
