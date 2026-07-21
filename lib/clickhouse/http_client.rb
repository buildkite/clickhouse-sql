# frozen_string_literal: true

require "date"
require "json"
require "logger"
require "net/http"
require "securerandom"
require "time"
require "uri"
require "zlib"

require_relative "http_client/error"
require_relative "http_client/value_normalization"
require_relative "http_client/database"
require_relative "http_client/query"
require_relative "http_client/parameter_serializer"
require_relative "http_client/response_formatter"

module ClickHouse
  # HTTP transport for ClickHouse queries: owns database configuration,
  # HTTP POST mechanics, parameter serialization, response typecasting,
  # logging, and instrumentation.
  #
  # Queries are duck-typed: any object responding to #to_sql (SQL text with
  # ClickHouse `{name:Type}` placeholders intact) and #placeholders (a Hash of
  # placeholder names to Ruby values) is accepted, as is a plain String of
  # trusted SQL. ClickHouse::SQL::Query satisfies this protocol; so does the
  # HTTPClient::Query value object. An object that also responds to
  # #to_query (e.g. ClickHouse::SQL::SelectQuery) is compiled through it
  # first, so builder-level validations always apply.
  #
  # nil placeholder values are always sent as NULL. Binding nil to a
  # non-Nullable placeholder type fails loudly in ClickHouse for most types,
  # but parses as an empty string for a plain String placeholder — callers
  # (e.g. ClickHouse::SQL) are expected to validate nil against placeholder
  # types before execution.
  #
  # Derived in part from GitLab's MIT-licensed click_house-client gem;
  # see LICENSE.
  module HTTPClient
    # Instrumentation event emitted around every query.
    NOTIFICATION_NAME = "sql.click_house"
    QUERY_ID_HEADER = "x-clickhouse-query-id"
    private_constant :QUERY_ID_HEADER

    # Successful outcome of a command-style query. Failures raise instead of
    # returning a result. Statistics are parsed from x-clickhouse-summary and
    # are final because every request sends wait_end_of_query=1.
    ExecutionResult = Data.define(:query_id, :statistics)

    NOOP_INSTRUMENTER = Object.new
    def NOOP_INSTRUMENTER.instrument(_name, payload)
      yield payload
    end
    private_constant :NOOP_INSTRUMENTER

    # Applications typically configure the logger, instrumenter, and database
    # registry once during initialization.
    class << self
      # @return [Logger] Structured query logger.
      attr_writer :logger # rubocop:disable ThreadSafety/ClassAndModuleAttributes

      def logger
        @logger ||= Logger.new(IO::NULL) # rubocop:disable ThreadSafety/ClassInstanceVariable
      end

      # @return [#instrument] Query instrumenter.
      attr_writer :instrumenter # rubocop:disable ThreadSafety/ClassAndModuleAttributes

      def instrumenter
        @instrumenter || NOOP_INSTRUMENTER # rubocop:disable ThreadSafety/ClassInstanceVariable
      end

      # Registers a database connection under a name.
      def register_database(name, **args)
        raise ConfigurationError, "The database '#{name}' is already registered" if databases.key?(name)

        databases[name] = Database.build(**args)
      end

      # @param name [Symbol] Registered database name.
      # @return [ClickHouse::HTTPClient::Database]
      def database(name)
        databases.fetch(name) do
          raise ConfigurationError, "The database '#{name}' is not registered"
        end
      end

      # Executes a SELECT query and returns rows as an Array of Hashes, with
      # values typecast according to the column types in the response. Callers
      # migrating an existing result contract can supply a formatter block,
      # which receives the parsed response including its column metadata.
      def select(query, database, timeout: nil, &formatter)
        query = Query.wrap(query)
        body, content_type = encode_multipart(form_data(query))

        run(query, database, timeout: timeout, body: body, extra_headers: { "Content-Type" => content_type }) do |response|
          parsed = parse_result_body(response)

          statistics = ValueNormalization.symbolize_keys(parsed["statistics"]) if parsed["statistics"]
          rows = formatter ? formatter.call(parsed) : ResponseFormatter.format_rows(parsed)
          [rows, statistics]
        end
      end

      # Executes any query without returning row data (INSERT, DELETE, DDL).
      #
      # @return [ClickHouse::HTTPClient::ExecutionResult]
      def execute(query, database, timeout: nil)
        query = Query.wrap(query)
        body, content_type = encode_multipart(form_data(query))

        run(query, database, timeout: timeout, body: body, extra_headers: { "Content-Type" => content_type }) do |response|
          statistics = summary_statistics(response)
          result = ExecutionResult.new(
            query_id: response[QUERY_ID_HEADER],
            statistics: statistics,
          )
          [result, statistics]
        end
      end

      # Inserts a gzip-compressed CSV IO to ClickHouse.
      #
      # Usage:
      #
      #   io = StringIO.new(gzip_compressed_csv)
      #   ClickHouse::HTTPClient.insert_csv("INSERT INTO events (id) FORMAT CSV", io, :main)
      #
      # @return [ClickHouse::HTTPClient::ExecutionResult]
      def insert_csv(query, io, database, timeout: nil)
        query = Query.wrap(query)

        # The request body carries the CSV data, so there's nowhere to send
        # param_* placeholder values; ClickHouse would receive unresolved
        # {name:Type} markers in the SQL.
        unless query.placeholders.empty?
          raise QueryError, "insert_csv does not support query placeholders"
        end

        run(query, database, timeout: timeout, body: io, extra_headers: CSV_HEADERS, uri_variables: { query: query.sql }) do |response|
          statistics = summary_statistics(response)
          result = ExecutionResult.new(
            query_id: response[QUERY_ID_HEADER],
            statistics: statistics,
          )
          [result, statistics]
        end
      end

      private

      CSV_HEADERS = { "Transfer-Encoding" => "chunked", "Content-Encoding" => "gzip" }.freeze

      def databases
        @databases ||= {} # rubocop:disable ThreadSafety/ClassInstanceVariable
      end

      def run(query, database_name, timeout:, body:, extra_headers:, uri_variables: {})
        db = database(database_name)
        uri = db.uri(uri_variables)

        logger.debug { { clickhouse_query: query.sql } }

        result = nil
        instrumenter.instrument(NOTIFICATION_NAME, { query: query, database: database_name }) do |instrument|
          response = begin
            perform_request(uri, db.headers.merge(extra_headers), body, timeout || 30)
          rescue Net::OpenTimeout => e
            raise ConnectionError, e.message
          rescue Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, Errno::ETIMEDOUT => e
            raise TimeoutError, e.message
          rescue SocketError, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
            Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, Zlib::Error => e
            raise ConnectionError, e.message
          end
          normalize_response_body(response)

          # The query ID correlates with ClickHouse's own system.query_log and
          # is useful to instrumentation even when ClickHouse rejects a query.
          instrument[:query_id] = response[QUERY_ID_HEADER]

          raise DatabaseError, response.body unless response.is_a?(Net::HTTPSuccess)

          result, statistics = yield(response)

          instrument[:statistics] = statistics

          result
        end
        result
      end

      def perform_request(uri, headers, body, timeout)
        request = Net::HTTP::Post.new(uri.request_uri, headers)
        if body.respond_to?(:read)
          request.body_stream = body
        else
          request.body = body
        end

        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 2,
          read_timeout: timeout,
          write_timeout: timeout,
          max_retries: 0,
        ) { |http| http.request(request) }
      end

      def form_data(query)
        query.placeholders.each_with_object({ "query" => query.sql }) do |(name, value), form|
          form["param_#{name}"] = ParameterSerializer.serialize(value)
        end
      end

      # Placeholders are sent as param_-prefixed multipart form fields
      # alongside the query, dodging URL length limits. Net::HTTP#set_form
      # writes non-chunked multipart requests through a Tempfile, so encode the
      # all-String subset used here directly instead.
      # See: https://github.com/ClickHouse/ClickHouse/issues/8842
      def encode_multipart(fields)
        boundary = "----RubyMultipart#{SecureRandom.hex(16)}"
        body = String.new(encoding: Encoding::BINARY)

        fields.each do |name, value|
          escaped_name = name.to_s
            .gsub(/["\\]/) { |character| "\\#{character}" }
            .gsub("\r", "%0D")
            .gsub("\n", "%0A")
          body << "--#{boundary}\r\n"
          body << "Content-Disposition: form-data; name=\"#{escaped_name}\"\r\n\r\n"
          body << value.b
          body << "\r\n"
        end

        body << "--#{boundary}--\r\n"
        [body, "multipart/form-data; boundary=#{boundary}"]
      end

      def normalize_response_body(response)
        return unless response.body

        /\bcharset=([^;]+)/.match(response["content-type"]) do |match|
          response.body.force_encoding(Encoding.find(match[1].strip))
        end
      rescue ArgumentError
        # Match Faraday's NetHTTP adapter: an unsupported charset leaves the
        # response body in its original binary encoding.
      end

      # A malformed body on a success status is still a server-side failure:
      # even with wait_end_of_query buffering, an error can slip in after the
      # response has been committed (e.g. the buffer overflowing to the
      # client). ClickHouse appends its error text to the body, so surface
      # the tail in the DatabaseError rather than a bare JSON::ParserError.
      def parse_result_body(response)
        JSON.parse(response.body)
      rescue JSON::ParserError
        body = response.body.to_s
        body_tail = body.length > 500 ? body[-500, 500] : body
        raise DatabaseError, "Malformed ClickHouse response body (HTTP #{response.code}), body tail: #{body_tail}"
      end

      def summary_statistics(headers)
        summary = headers["x-clickhouse-summary"]
        return {}.freeze unless summary

        # The `x-clickhouse-summary` header encodes its numeric values as
        # strings, unlike the `statistics` block in the JSON body which uses
        # real numbers. Coerce them so instrumentation receives numeric metrics
        # consistently across query paths.
        ValueNormalization
          .symbolize_keys(JSON.parse(summary))
          .transform_values { |value| coerce_numeric(value) }
          .freeze
      end

      def coerce_numeric(value)
        return value unless value.is_a?(String)

        Integer(value, exception: false) || Float(value, exception: false) || value
      end
    end
  end
end
