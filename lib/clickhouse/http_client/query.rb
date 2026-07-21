# frozen_string_literal: true

module ClickHouse
  module HTTPClient
    # Immutable query value object: SQL text with ClickHouse `{name:Type}`
    # placeholders, plus the placeholder values to bind. Also the normal form
    # every accepted query is converted into at the client boundary.
    Query = Data.define(:sql, :placeholders) do
      # Accepts a String of trusted SQL or any object honoring the query
      # protocol (#to_sql and #placeholders).
      #
      # @param query [String, #to_sql & #placeholders]
      # @return [ClickHouse::HTTPClient::Query]
      def self.wrap(query)
        case query
        when String
          new(sql: query)
        else
          # A builder that can compile itself (e.g. ClickHouse::SQL's
          # SelectQuery#to_query) does so here, so its compile-time
          # validations — like the nil-placeholder net — apply even when a
          # caller passes the builder directly instead of calling #to_query.
          # The arity check excludes ActiveSupport's unrelated
          # Object#to_query(namespace), which every object responds to.
          if query.respond_to?(:to_query) && query.method(:to_query).arity.zero?
            query = query.to_query
          end

          unless query.respond_to?(:to_sql) && query.respond_to?(:placeholders)
            raise QueryError, "Expected a SQL string or an object responding to #to_sql and #placeholders, got #{query.class}"
          end

          new(sql: query.to_sql, placeholders: query.placeholders)
        end
      end

      def initialize(sql:, placeholders: {})
        raise QueryError, "Empty query string given" if sql.to_s.strip.empty?

        super(
          sql: -sql.to_s,
          placeholders: ValueNormalization.immutable_copy(
            ValueNormalization.symbolize_keys(placeholders || {}),
          ),
        )
      end

      # @return [String] SQL query text.
      def to_sql
        sql
      end
    end
  end
end
