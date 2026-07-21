# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"
require "webmock/rspec"

require_relative "../../../lib/clickhouse/http_client"

RSpec.describe ClickHouse::HTTPClient do
  describe "framework independence" do
    it "loads without ActiveSupport, Addressable, Datadog, Faraday, or multipart dependencies" do
      source = <<~'RUBY'
        require "clickhouse/http_client"

        parsed = {
          "meta" => [
            { "name" => "timestamp", "type" => "DateTime64(6, 'UTC')" },
            { "name" => "interval", "type" => "IntervalMillisecond" },
          ],
          "data" => [{ "timestamp" => "2026-07-06 01:02:03.123456", "interval" => "1" }],
        }
        row = ClickHouse::HTTPClient.const_get(:ResponseFormatter).format_rows(parsed).fetch(0)
        abort row.inspect unless row.fetch("timestamp").instance_of?(Time) && row.fetch("timestamp").utc?
        abort row.inspect unless row.fetch("timestamp").nsec == 123_456_000 && row.fetch("interval") == 0.001

        statistics = ClickHouse::HTTPClient.send(
          :summary_statistics,
          { "x-clickhouse-summary" => '{"read_rows":"10"}' }
        )
        abort statistics.inspect unless statistics == { read_rows: 10 }

        payload = {}
        result = ClickHouse::HTTPClient.instrumenter.instrument("test", payload) do |mutable_payload|
          mutable_payload[:called] = true
          :result
        end
        abort payload.inspect unless result == :result && payload == { called: true }

        begin
          ClickHouse::HTTPClient.instrumenter.instrument("test", {}) { raise "boom" }
        rescue RuntimeError => error
          abort error.message unless error.message == "boom"
        else
          abort "instrumenter swallowed exception"
        end

        loaded = $LOADED_FEATURES.grep(%r{/(?:active_support|addressable|datadog|faraday|faraday-multipart|multipart-post)(?:/|\.rb\z)})
        abort loaded.join("\n") unless loaded.empty?
      RUBY

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I",
        File.expand_path("../../../lib", __dir__),
        "-e",
        source
      )

      expect(status).to be_success, "subprocess failed:\n#{stdout}\n#{stderr}"
    end
  end

  describe "instrumentation protocol" do
    let(:database) { :"http_client_instrumentation_spec_#{object_id}" }
    let(:instrumenter) do
      Class.new do
        attr_reader :name, :payload

        def instrument(name, payload)
          @name = name
          @payload = payload
          [:instrumented, yield(payload)]
        end
      end.new
    end

    before do
      described_class.register_database(
        database,
        database: "spec_db",
        url: "http://clickhouse-instrumentation-spec.test:8123",
        username: "spec_user",
        password: "spec_pass",
      )
    end

    around do |example|
      previous_instrumenter = described_class.instrumenter
      described_class.instrumenter = instrumenter
      example.run
    ensure
      described_class.instrumenter = previous_instrumenter
    end

    it "exposes mutable response context without replacing the query result" do
      stub_request(:post, "http://clickhouse-instrumentation-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(
          status: 200,
          body: "",
          headers: {
            "x-clickhouse-query-id" => "query-123",
            "x-clickhouse-summary" => { read_rows: "10" }.to_json,
          },
        )

      result = described_class.execute("INSERT INTO t VALUES (1)", database)

      expect(result).to be_a(described_class::ExecutionResult)
      expect(result).to have_attributes(query_id: "query-123", statistics: { read_rows: 10 })
      expect(instrumenter.name).to eq("sql.click_house")
      expect(instrumenter.payload).to include(
        database: database,
        query: have_attributes(to_sql: "INSERT INTO t VALUES (1)"),
        query_id: "query-123",
        statistics: { read_rows: 10 },
      )
    end

    it "exposes the query ID when ClickHouse rejects a query" do
      stub_request(:post, "http://clickhouse-instrumentation-spec.test:8123/")
        .with(query: hash_including("database" => "spec_db"))
        .to_return(
          status: 400,
          body: "Code: 62. DB::Exception: Syntax error",
          headers: { "x-clickhouse-query-id" => "failed-456" },
        )

      expect {
        described_class.execute("BROKEN", database)
      }.to raise_error(described_class::DatabaseError, /Syntax error/)

      expect(instrumenter.payload).to include(query_id: "failed-456")
    end
  end
end
