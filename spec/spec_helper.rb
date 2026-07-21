# frozen_string_literal: true

require "webmock/rspec"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.filter_run_excluding integration: true unless ENV["CLICKHOUSE_URL"]
end

WebMock.disable_net_connect!
