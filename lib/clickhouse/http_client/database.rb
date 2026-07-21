# frozen_string_literal: true

module ClickHouse
  module HTTPClient
    # Connection settings and headers for one registered ClickHouse database.
    Database = Data.define(:url, :variables, :headers) do
      def self.build(database:, url:, username:, password:, variables: {})
        new(
          url: url,
          variables: {
            database: database,
            enable_http_compression: 1,
            # Buffer each response server-side before sending: without this,
            # ClickHouse commits HTTP 200 once it starts streaming, and an
            # error later in query execution (memory limit, server-side
            # timeout) is appended to the already-started body rather than
            # producing an error status.
            wait_end_of_query: 1,
          }.merge(variables).freeze,
          headers: {
            "X-ClickHouse-User" => username,
            "X-ClickHouse-Key" => password,
            "X-ClickHouse-Format" => "JSON", # always return JSON data
          }.freeze,
        )
      end

      # @return [String] Physical ClickHouse database name.
      def database_name
        variables.fetch(:database)
      end

      # @param extra_variables [Hash] Additional URL query parameters.
      # @return [URI::HTTP] Endpoint URI for this database.
      def uri(extra_variables = {})
        URI.parse(url).tap do |uri|
          uri.query = URI.encode_www_form(variables.merge(extra_variables))
        end
      end
    end
  end
end
