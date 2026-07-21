# frozen_string_literal: true

require "securerandom"
require "stringio"
require "uri"
require "zlib"

require "spec_helper"

require_relative "../../../lib/clickhouse/http_client"

RSpec.describe ClickHouse::HTTPClient do
  describe "database registry" do
    it "exposes the physical database name" do
      described_class.register_database(
        :example,
        database: "example_database",
        url: "http://example.com",
        username: "username",
        password: "password",
      )

      expect(described_class.database(:example).database_name).to eq("example_database")
    end

    it "raises for an unregistered database" do
      expect {
        described_class.database(:nope)
      }.to raise_error(described_class::ConfigurationError, /not registered/)
    end

    it "raises when registering a duplicate database" do
      described_class.register_database(:duplicate_example, database: "x", url: "http://x", username: "u", password: "p")

      expect {
        described_class.register_database(:duplicate_example, database: "x", url: "http://x", username: "u", password: "p")
      }.to raise_error(described_class::ConfigurationError, /already registered/)
    end

    it "builds an HTTP URI with encoded database and request variables" do
      described_class.register_database(
        :uri_example,
        database: "example_database",
        url: "http://example.com/clickhouse?discard=me",
        username: "username",
        password: "password",
        variables: { setting: "database value", array: ["first", "second"] },
      )

      uri = described_class.database(:uri_example).uri(
        setting: "+/?&= こんにちは",
        optional: nil,
      )

      expect(uri).to be_instance_of(URI::HTTP)
      expect(URI.decode_www_form(uri.query)).to contain_exactly(
        ["database", "example_database"],
        ["enable_http_compression", "1"],
        ["wait_end_of_query", "1"],
        ["setting", "+/?&= こんにちは"],
        ["array", "first"],
        ["array", "second"],
        ["optional", ""],
      )
    end

    it "builds an HTTPS URI" do
      described_class.register_database(
        :https_uri_example,
        database: "example_database",
        url: "https://example.com/clickhouse",
        username: "username",
        password: "password",
      )

      expect(described_class.database(:https_uri_example).uri).to be_instance_of(URI::HTTPS)
    end
  end

  describe "HTTP transport" do
    # A stubbed remote lets these examples assert on the exact wire format
    # without a ClickHouse server: URI, headers, and form fields.
    before do
      begin
        described_class.database(:http_client_spec)
      rescue described_class::ConfigurationError
        described_class.register_database(
          :http_client_spec,
          database: "spec_db",
          url: "http://clickhouse-spec.test:8123",
          username: "spec_user",
          password: "spec_pass",
          variables: { join_use_nulls: 1 },
        )
      end
    end

    let(:empty_result) { { meta: [], data: [], statistics: { elapsed: 0.1, rows_read: 0, bytes_read: 0 } }.to_json }

    it "POSTs binary-safe query and serialized param_ fields with ClickHouse headers" do
      sql = "SELECT {label:String} AS café"
      label = "line one\nC:\\temp"
      stub = stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(
          query: { "database" => "spec_db", "enable_http_compression" => "1", "wait_end_of_query" => "1", "join_use_nulls" => "1" },
          headers: {
            "X-ClickHouse-User" => "spec_user",
            "X-ClickHouse-Key" => "spec_pass",
            "X-ClickHouse-Format" => "JSON",
            "Content-Type" => %r{multipart/form-data},
          },
        ) { |request|
          boundary = request.headers.fetch("Content-Type").match(/boundary=(.+)\z/)&.[](1)
          boundary && request.body.b == [
            "--#{boundary}\r\n",
            "Content-Disposition: form-data; name=\"query\"\r\n\r\n",
            sql,
            "\r\n--#{boundary}\r\n",
            "Content-Disposition: form-data; name=\"param_label\"\r\n\r\n",
            "line one\\nC:\\\\temp",
            "\r\n--#{boundary}--\r\n",
          ].join.b
        }
        .to_return(status: 200, body: empty_result)

      described_class.select(
        described_class::Query.new(sql: sql, placeholders: { label: label }),
        :http_client_spec,
      )

      expect(stub).to have_been_requested
    end

    it "configures default open, read, and write timeouts without retries" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 200, body: empty_result)
      expect(Net::HTTP).to receive(:start).with(
        "clickhouse-spec.test",
        8123,
        use_ssl: false,
        open_timeout: 2,
        read_timeout: 30,
        write_timeout: 30,
        max_retries: 0,
      ).and_call_original

      described_class.select("SELECT 1", :http_client_spec)
    end

    it "applies a per-query read and write timeout" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 200, body: empty_result)
      expect(Net::HTTP).to receive(:start).with(
        "clickhouse-spec.test",
        8123,
        use_ssl: false,
        open_timeout: 2,
        read_timeout: 1.5,
        write_timeout: 1.5,
        max_retries: 0,
      ).and_call_original

      described_class.select("SELECT 1", :http_client_spec, timeout: 1.5)
    end

    it "typecasts select results according to the response meta types" do
      body = {
        meta: [
          { name: "uint64", type: "UInt64" },
          { name: "int64_null", type: "Nullable(Int64)" },
          { name: "float", type: "Float64" },
          { name: "date", type: "Date" },
          { name: "datetime", type: "DateTime64(6, 'UTC')" },
          { name: "interval_second", type: "IntervalSecond" },
          { name: "interval_millisecond", type: "IntervalMillisecond" },
          { name: "low_cardinality", type: "LowCardinality(String)" },
          { name: "aggregate", type: "SimpleAggregateFunction(sum, UInt64)" },
          { name: "offshore", type: "DateTime64(6, 'Australia/Melbourne')" },
          { name: "unknown", type: "Tuple(UInt8, String)" },
          { name: "array_uint64", type: "Array(UInt64)" },
          { name: "array_nullable", type: "Array(Nullable(UInt64))" },
          { name: "array_datetime", type: "Array(DateTime64(3, 'UTC'))" },
          { name: "array_string", type: "Array(String)" },
          { name: "array_nested", type: "Array(Array(UInt64))" },
          { name: "array_offshore", type: "Array(DateTime64(6, 'Australia/Melbourne'))" },
        ],
        data: [
          {
            uint64: "42",
            int64_null: nil,
            float: 1.5,
            date: "2026-07-06",
            datetime: "2026-07-06 01:02:03.123456",
            interval_second: "1",
            interval_millisecond: "1",
            low_cardinality: "label",
            aggregate: "7",
            offshore: "2026-07-06 11:02:03.000000",
            unknown: [1, "x"],
            array_uint64: ["1", "2"],
            array_nullable: [nil, "3"],
            array_datetime: ["2026-07-06 01:02:03.123"],
            array_string: ["a", "b"],
            array_nested: [["1"], ["2", "3"]],
            array_offshore: ["2026-07-06 11:02:03.000000"],
          },
        ],
        statistics: { elapsed: 0.1, rows_read: 1, bytes_read: 10 },
      }.to_json

      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 200, body: body)

      rows = described_class.select("SELECT irrelevant", :http_client_spec)

      expect(rows).to eq([
        {
          "uint64" => 42,
          "int64_null" => nil,
          "float" => 1.5,
          "date" => Date.new(2026, 7, 6),
          "datetime" => Time.utc(2026, 7, 6, 1, 2, 3, 123_456),
          "interval_second" => 1,
          "interval_millisecond" => 0.001,
          "low_cardinality" => "label",
          "aggregate" => 7,
          # Only UTC datetimes are typecast; other zones pass through as strings.
          "offshore" => "2026-07-06 11:02:03.000000",
          "unknown" => [1, "x"],
          # Array elements are typecast the same way scalars are — JSON quotes
          # 64-bit integers, so Array(UInt64) arrives as an array of strings.
          "array_uint64" => [1, 2],
          "array_nullable" => [nil, 3],
          "array_datetime" => [Time.utc(2026, 7, 6, 1, 2, 3, 123_000)],
          "array_string" => ["a", "b"],
          "array_nested" => [[1], [2, 3]],
          "array_offshore" => ["2026-07-06 11:02:03.000000"],
        },
      ])

      datetime = rows.first.fetch("datetime")
      expect(datetime).to be_instance_of(Time)
      expect(datetime).to be_utc
      expect(datetime.nsec).to eq(123_456_000)
      expect(rows.first.fetch("interval_second")).to be_instance_of(Integer)
      expect(rows.first.fetch("interval_millisecond")).to be_instance_of(Float)
    end

    it "allows callers to format select results from the response metadata" do
      body = {
        meta: [{ name: "timestamp", type: "DateTime64(6)" }],
        data: [{ timestamp: "2026-07-17 06:27:20.123456" }],
        statistics: { elapsed: 0.1, rows_read: 1, bytes_read: 10 },
      }.to_json
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 200, body: body)

      rows = described_class.select("SELECT timestamp", :http_client_spec) do |parsed|
        expect(parsed.fetch("meta")).to eq([{ "name" => "timestamp", "type" => "DateTime64(6)" }])
        parsed.fetch("data")
      end

      expect(rows).to eq([{ "timestamp" => "2026-07-17 06:27:20.123456" }])
    end

    it "returns the query ID and numeric summary statistics from execute" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(
          status: 200,
          body: "",
          headers: {
            "x-clickhouse-query-id" => "execute-123",
            "x-clickhouse-summary" => { written_rows: "5", elapsed: "0.125", result: "complete" }.to_json,
          },
        )

      result = described_class.execute("INSERT INTO events VALUES (1)", :http_client_spec)

      expect(result).to be_a(described_class::ExecutionResult)
      expect(result.query_id).to eq("execute-123")
      expect(result.statistics).to eq(written_rows: 5, elapsed: 0.125, result: "complete")
      expect(result.statistics).to be_frozen
    end

    it "returns empty execution context when execute response headers are absent" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 200, body: "")

      result = described_class.execute("INSERT INTO events VALUES (1)", :http_client_spec)

      expect(result).to have_attributes(query_id: nil, statistics: {})
      expect(result.statistics).to be_frozen
    end

    it "returns an ExecutionResult from insert_csv" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db", "query" => "INSERT INTO events FORMAT CSV"))
        .to_return(
          status: 200,
          body: "",
          headers: {
            "x-clickhouse-query-id" => "csv-123",
            "x-clickhouse-summary" => { written_rows: "2" }.to_json,
          },
        )

      result = described_class.insert_csv("INSERT INTO events FORMAT CSV", StringIO.new, :http_client_spec)

      expect(result).to be_a(described_class::ExecutionResult)
      expect(result).to have_attributes(query_id: "csv-123", statistics: { written_rows: 2 })
    end

    it "rejects insert_csv queries with placeholders" do
      query = described_class::Query.new(
        sql: "INSERT INTO events SELECT id FROM input('id UInt64') WHERE org = {org:String} FORMAT CSV",
        placeholders: { org: "acme" },
      )

      expect {
        described_class.insert_csv(query, StringIO.new, :http_client_spec)
      }.to raise_error(described_class::QueryError, /placeholders/)
    end

    it "wraps open timeouts as ConnectionError, keeping the cause" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_raise(Net::OpenTimeout.new("execution expired"))

      expect {
        described_class.select("SELECT 1", :http_client_spec)
      }.to raise_error(described_class::ConnectionError) { |error|
        expect(error.cause).to be_a(Net::OpenTimeout)
      }
    end

    it "wraps client-side read timeouts as TimeoutError, keeping the cause" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_raise(Net::ReadTimeout.new("execution expired"))

      expect {
        described_class.select("SELECT 1", :http_client_spec)
      }.to raise_error(described_class::TimeoutError) { |error|
        expect(error.cause).to be_a(Net::ReadTimeout)
      }
    end

    it "wraps socket and protocol failures as ConnectionError, keeping the cause" do
      [SocketError.new("not known"), Net::HTTPBadResponse.new("wrong status line")].each do |failure|
        stub_request(:post, "http://clickhouse-spec.test:8123/")
          .with(query: hash_including("database" => "spec_db"))
          .to_raise(failure)

        expect {
          described_class.select("SELECT 1", :http_client_spec)
        }.to raise_error(described_class::ConnectionError) { |error|
          expect(error.cause).to be_a(failure.class)
        }
      end
    end

    it "raises DatabaseError with the response body on failure" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 400, body: "Code: 62. DB::Exception: Syntax error")

      expect {
        described_class.execute("BROKEN", :http_client_spec)
      }.to raise_error(described_class::DatabaseError, /Syntax error/)
    end

    it "preserves the declared encoding of a Unicode error body" do
      body = "DB::Exception: café".encode(Encoding::UTF_8).b
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 400, body: body, headers: { "Content-Type" => "text/plain; charset=UTF-8" })

      expect {
        described_class.execute("BROKEN", :http_client_spec)
      }.to raise_error(described_class::DatabaseError) { |error|
        expect(error.message).to eq("DB::Exception: café")
        expect(error.message.encoding).to eq(Encoding::UTF_8)
      }
    end

    it "still raises DatabaseError when the response charset is unsupported" do
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(
          status: 400,
          body: "DB::Exception: failure",
          headers: { "Content-Type" => "text/plain; charset=unknown-charset" },
        )

      expect {
        described_class.execute("BROKEN", :http_client_spec)
      }.to raise_error(described_class::DatabaseError, "DB::Exception: failure")
    end

    it "streams gzip CSV with chunked transfer encoding and the query in the URI" do
      csv = "compressed csv bytes".b
      io = StringIO.new(csv)
      allow(Net::HTTP::Post).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        candidate = original.call(*args, **kwargs)
        if candidate["X-ClickHouse-User"] == "spec_user"
          allow(candidate).to receive(:body_stream=).and_call_original
          expect(candidate).to receive(:body_stream=).with(io).and_call_original
        end
        candidate
      end
      stub = stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(
          query: hash_including("database" => "spec_db", "query" => "INSERT INTO events FORMAT CSV"),
          headers: { "Content-Encoding" => "gzip", "Transfer-Encoding" => "chunked" },
          body: csv,
        )
        .to_return(status: 200, body: "")

      described_class.insert_csv("INSERT INTO events FORMAT CSV", io, :http_client_spec)

      expect(stub).to have_been_requested
    end

    it "raises DatabaseError with a short malformed 200 response body" do
      # ClickHouse commits HTTP 200 once it starts streaming; an error later
      # in execution is appended to the body, truncating the JSON. The error
      # text lives at the tail of the body.
      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 200, body: '{"meta":[],"data":[Code: 241. DB::Exception: Memory limit (total) exceeded')

      expect {
        described_class.select("SELECT big", :http_client_spec)
      }.to raise_error(described_class::DatabaseError, /Malformed ClickHouse response body.*Memory limit/)
    end

    it "raises DatabaseError with only the tail of a long malformed 200 response body" do
      body = "discarded-prefix-" + ("x" * 600) + "Code: 241. DB::Exception: Memory limit exceeded"

      stub_request(:post, "http://clickhouse-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(status: 200, body: body)

      expect {
        described_class.select("SELECT big", :http_client_spec)
      }.to raise_error(described_class::DatabaseError) { |error|
        expect(error.message).to end_with(body[-500, 500])
        expect(error.message).not_to include("discarded-prefix")
      }
    end

  end

  describe "against a real ClickHouse server", :integration do
    # These examples round-trip through the ClickHouse server from
    # docker-compose, locking in the wire format end to end.
    let(:database) { :http_client_integration }

    around do |example|
      url = ENV.fetch("CLICKHOUSE_URL")
      uri = URI.parse(url)
      WebMock.disable_net_connect!(allow: ->(request_uri) { request_uri.host == uri.host && request_uri.port == uri.port })
      described_class.register_database(
        database,
        database: ENV.fetch("CLICKHOUSE_DATABASE", "default"),
        url: url,
        username: ENV.fetch("CLICKHOUSE_USERNAME", "default"),
        password: ENV.fetch("CLICKHOUSE_PASSWORD", ""),
      )

      example.run
    ensure
      WebMock.disable_net_connect!
    end

    it "binds typed placeholders and typecasts the results" do
      query = described_class::Query.new(
        sql: <<~SQL,
          SELECT {id:UInt64} AS id,
                 {name:Nullable(String)} AS name,
                 {labels:Array(Nullable(String))} AS labels,
                 {metadata:Map(String, Nullable(String))} AS metadata,
                 {nums:Array(UInt64)} AS nums,
                 {day:Date} AS day
        SQL
        placeholders: {
          id: 42,
          name: nil,
          labels: ["g'day", nil, "wor\\d"],
          metadata: { "present" => "x", "missing" => nil },
          nums: [1, 2],
          day: Date.new(2026, 7, 6),
        },
      )

      rows = described_class.select(query, database)

      expect(rows).to eq([
        {
          "id" => 42,
          "name" => nil,
          "labels" => ["g'day", nil, "wor\\d"],
          "metadata" => { "present" => "x", "missing" => nil },
          "nums" => [1, 2],
          "day" => Date.new(2026, 7, 6),
        },
      ])
    end

    it "round-trips String placeholders containing backslashes, tabs, and newlines" do
      # ClickHouse parses top-level String parameters in its escaped text
      # format: backslash sequences are decoded, and a literal TAB or LF
      # terminates the value. These values corrupt or fail without escaping.
      values = {
        windows_path: "C:\\temp",
        namespaced_handler: "Company\\Product\\Handler",
        null_marker: "\\N",
        tabbed: "a\tb",
        multiline: "line one\nline two\r\nline three",
      }

      query = described_class::Query.new(
        sql: "SELECT #{values.keys.map { |name| "{#{name}:String} AS #{name}" }.join(", ")}",
        placeholders: values,
      )

      rows = described_class.select(query, database)

      expect(rows).to eq([values.transform_keys(&:to_s)])
    end

    it "executes DDL and inserts gzipped CSV" do
      table = "http_client_spec_#{SecureRandom.hex(4)}"

      create_result = described_class.execute("CREATE TABLE #{table} (id UInt64, label Nullable(String)) ENGINE = Memory", database)

      compressed = StringIO.new
      gzip = Zlib::GzipWriter.new(compressed)
      gzip.write("1,one\n2,\\N\n")
      gzip.close
      io = StringIO.new(compressed.string)
      insert_query = <<~SQL.chomp
        INSERT INTO #{table} (id, label)
        -- URL encoding: spaces + / ? & = こんにちは
        FORMAT CSV
      SQL
      insert_result = described_class.insert_csv(insert_query, io, database)

      expect(create_result.query_id).to be_a(String)
      expect(create_result.query_id).not_to be_empty
      expect(insert_result.query_id).to be_a(String)
      expect(insert_result.query_id).not_to be_empty
      expect(insert_result.statistics.fetch(:written_rows)).to eq(2)

      rows = described_class.select("SELECT id, label FROM #{table} ORDER BY id", database)
      expect(rows).to eq([
        { "id" => 1, "label" => "one" },
        { "id" => 2, "label" => nil },
      ])
    ensure
      described_class.execute("DROP TABLE IF EXISTS #{table}", database)
    end

    it "applies per-query timeouts, raising the wrapped TimeoutError" do
      expect {
        described_class.select("SELECT sleep(2)", database, timeout: 0.5)
      }.to raise_error(described_class::TimeoutError) { |error|
        expect(error.cause).to be_a(Net::ReadTimeout)
      }
    end
  end
end
