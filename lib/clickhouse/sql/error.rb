# frozen_string_literal: true

module ClickHouse
  module SQL
    # Raised when ClickHouse::SQL cannot safely build or validate a query.
    #
    # Deliberately not a ClickHouse::HTTPClient error: a query-building error
    # is a caller bug in this layer, raised before anything reaches the
    # client. Rescue it alongside ClickHouse::HTTPClient errors where callers
    # degrade gracefully on query failure.
    class Error < StandardError; end
  end
end
