# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = "octri"
  s.version = "0.0.0"
  s.summary = "Server-side error monitoring for Ruby backends (Rack / Rails)."
  s.description = "Reports backend errors to your Octri monitoring project and links them to " \
                  "client SDK errors via W3C trace context; times requests and sub-spans into " \
                  "the request waterfall."
  s.authors = ["Octri"]
  s.license = "MIT"
  s.files = Dir["lib/**/*.rb", "README.md"]
  s.require_paths = ["lib"]
  s.required_ruby_version = ">= 2.7"
end
