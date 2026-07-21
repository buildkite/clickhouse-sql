# frozen_string_literal: true

require_relative "lib/clickhouse/sql/version"

Gem::Specification.new do |spec|
  spec.name = "clickhouse-sql"
  spec.version = ClickHouse::SQL::VERSION
  spec.authors = ["Buildkite"]
  spec.email = ["paul@buildkite.com"]

  spec.summary = "A typed ClickHouse SQL query builder and HTTP transport client"
  spec.description = "Build composable ClickHouse SELECT queries with typed placeholders and execute them over HTTP."
  spec.homepage = "https://github.com/buildkite/clickhouse-sql"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "#{spec.homepage}/tree/main",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "activesupport", ">= 8.0", "< 9"
  spec.add_development_dependency "rake", "~> 13.4"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.26"
end
