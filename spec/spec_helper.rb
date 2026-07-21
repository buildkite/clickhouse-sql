# frozen_string_literal: true

require "webmock/rspec"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.filter_run_excluding integration: true unless ENV["CLICKHOUSE_URL"]

  config.around do |example|
    client = ClickHouse::HTTPClient if defined?(ClickHouse::HTTPClient)
    variables = %i[@databases @instrumenter @logger]
    state = variables.to_h do |variable|
      defined = client&.instance_variable_defined?(variable)
      value = client&.instance_variable_get(variable)
      value = value.dup if variable == :@databases && value
      [variable, [defined, value]]
    end

    example.run
  ensure
    if client
      state.each do |variable, (defined, value)|
        if defined
          client.instance_variable_set(variable, value)
        elsif client.instance_variable_defined?(variable)
          client.remove_instance_variable(variable)
        end
      end
    end
  end
end

WebMock.disable_net_connect!
