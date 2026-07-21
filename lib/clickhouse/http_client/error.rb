# frozen_string_literal: true

module ClickHouse
  module HTTPClient
    Error = Class.new(StandardError)
    ConfigurationError = Class.new(Error)
    DatabaseError = Class.new(Error)
    QueryError = Class.new(Error)

    # Transport failures are re-raised as these wrappers (with the original
    # Net::HTTP error as the cause) so callers rescue one hierarchy without
    # knowing the underlying HTTP library. TimeoutError is the client giving
    # up waiting; a server-side kill (max_execution_time) surfaces as a
    # DatabaseError mentioning TIMEOUT_EXCEEDED instead.
    ConnectionError = Class.new(Error)
    TimeoutError = Class.new(Error)
  end
end
