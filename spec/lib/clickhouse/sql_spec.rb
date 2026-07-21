# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

require_relative "../../../lib/clickhouse/sql"

RSpec.describe ClickHouse::SQL do
  let(:uuid) { "018f3f4a-8f58-7c3f-8b5c-0f6f30fd9ed1" }

  describe "framework independence" do
    it "loads and builds queries in a fresh Ruby process without ActiveSupport or Datadog" do
      source = <<~'RUBY'
        require "clickhouse/sql"

        query = ClickHouse::SQL
          .select("id")
          .from("requests")
          .where("id = {id:UInt64}", id: "42")
          .to_query

        abort "query construction failed" unless query.placeholders == { id: 42 }

        loaded = $LOADED_FEATURES.grep(%r{/(?:active_support|datadog)(?:/|\.rb\z)})
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

  describe ".parse_placeholders" do
    it "parses placeholders with whitespace, nested type arguments, and parameterized types" do
      placeholders = described_class.parse_placeholders(
        "id IN { ids:Array(Nullable(UUID)) } AND ts >= {ts:DateTime64(6, 'UTC')}"
      )

      expect(placeholders.map { [_1.name, _1.type] }).to eq([
        ["ids", "Array(Nullable(UUID))"],
        ["ts", "DateTime64(6, 'UTC')"],
      ])
    end

    it "rejects unclosed placeholders instead of treating malformed SQL as raw text" do
      expect do
        described_class.parse_placeholders("id = {id:UUID")
      end.to raise_error(ClickHouse::SQL::Error, /Unclosed ClickHouse placeholder/)
    end

    it "parses anonymous {} fragment slots" do
      placeholders = described_class.parse_placeholders("{} = {} AND id = {id:UUID}")

      expect(placeholders.map { [_1.name, _1.type, _1.anonymous?] }).to eq([
        [nil, nil, true],
        [nil, nil, true],
        ["id", "UUID", false],
      ])
    end

    it "rejects invalid placeholder names" do
      expect do
        described_class.parse_placeholders("id = {id-name:UUID}")
      end.to raise_error(ClickHouse::SQL::Error, /Invalid ClickHouse placeholder/)
    end

    it "rejects anonymous typed placeholders" do
      expect do
        described_class.parse_placeholders("id = {:UUID}")
      end.to raise_error(ClickHouse::SQL::Error, /Invalid ClickHouse placeholder/)
    end

    it "rejects placeholders with an empty type after the colon" do
      expect do
        described_class.parse_placeholders("id = {id:}")
      end.to raise_error(ClickHouse::SQL::Error, /Invalid ClickHouse placeholder/)

      expect do
        described_class.parse_placeholders("id = {id: }")
      end.to raise_error(ClickHouse::SQL::Error, /Invalid ClickHouse placeholder/)
    end
  end

  describe ".split_top_level_arguments" do
    it "splits on top-level commas only" do
      expect(described_class.split_top_level_arguments("6, 'UTC'")).to eq(["6", "'UTC'"])
      expect(described_class.split_top_level_arguments("Tuple(UInt8, String), UInt8"))
        .to eq(["Tuple(UInt8, String)", "UInt8"])
    end

    it "ignores commas inside quoted strings" do
      expect(described_class.split_top_level_arguments("'a,b', 'c'")).to eq(["'a,b'", "'c'"])
    end

    it "treats escaped quotes as part of the quoted string" do
      expect(described_class.split_top_level_arguments("'don\\'t, oops' = 1, 'b' = 2"))
        .to eq(["'don\\'t, oops' = 1", "'b' = 2"])
    end

    it "closes a quoted string after an escaped backslash" do
      expect(described_class.split_top_level_arguments("'a\\\\', 'b'")).to eq(["'a\\\\'", "'b'"])
    end
  end

  describe ".fragment" do
    it "keeps ClickHouse typed placeholders in SQL and carries values separately" do
      fragment = described_class.fragment(
        "organization_id = { organization_id:UUID } AND endpoint_id IN {endpoint_ids:Array(UUID)}",
        organization_id: uuid,
        endpoint_ids: [uuid]
      )

      expect(fragment.to_sql).to eq("organization_id = { organization_id:UUID } AND endpoint_id IN {endpoint_ids:Array(UUID)}")
      expect(fragment.placeholders).to eq(organization_id: uuid, endpoint_ids: [uuid])
      expect(fragment.placeholder_types).to eq(organization_id: "UUID", endpoint_ids: "Array(UUID)")
    end

    it "redacts placeholders with whitespace, nested types, and parameterized types" do
      fragment = described_class.fragment(
        "id IN { ids:Array(Nullable(UUID)) } AND timestamp >= {ts:DateTime64(6, 'UTC')}",
        ids: [uuid, nil],
        ts: Time.utc(2026, 7, 1, 12, 13, 14, 123_456)
      )

      expect(fragment.to_redacted_sql).to eq("id IN $1 AND timestamp >= $2")
      expect(fragment.placeholders.fetch(:ts)).to eq("2026-07-01 12:13:14.123456")
    end

    it "composes fragment slots without letting runtime strings become SQL" do
      column = described_class.raw_static("requests.attributes.{attribute_key:Identifier}")
      fragment = described_class.fragment("{column} = {attribute_value:String}", column:, attribute_value: "GET")

      expect(fragment.to_sql).to eq("requests.attributes.{attribute_key:Identifier} = {attribute_value:String}")
      expect(fragment.placeholders).to eq(attribute_value: "GET")
    end

    it "collects placeholders from nested fragment slots" do
      column = described_class.fragment("requests.attributes.{attribute_key:Identifier}", attribute_key: "http.method")
      fragment = described_class.fragment("{column} = {attribute_value:String}", column:, attribute_value: "GET")

      expect(fragment.to_sql).to eq("requests.attributes.{attribute_key:Identifier} = {attribute_value:String}")
      expect(fragment.placeholders).to eq(attribute_value: "GET", attribute_key: "http.method")
      expect(fragment.to_redacted_sql).to eq("requests.attributes.$1 = $2")
    end

    it "fills anonymous {} slots in source order from positional arguments" do
      left = described_class.raw_static("r.id")
      right = described_class.fragment("requests.attributes.{attribute_key:Identifier}", attribute_key: "http.method")
      fragment = described_class.fragment("{} = {} AND status = {status:String}", left, right, status: "completed")

      expect(fragment.to_sql).to eq("r.id = requests.attributes.{attribute_key:Identifier} AND status = {status:String}")
      expect(fragment.placeholders).to eq(status: "completed", attribute_key: "http.method")
      expect(fragment.to_redacted_sql).to eq("r.id = requests.attributes.$1 AND status = $2")
    end

    it "mixes anonymous and named fragment slots" do
      left = described_class.raw_static("r.id")
      right = described_class.raw_static("requests.endpoint_id")
      fragment = described_class.fragment("{} = {other}", left, other: right)

      expect(fragment.to_sql).to eq("r.id = requests.endpoint_id")
    end

    it "rejects mismatched anonymous slot and fill counts" do
      part = described_class.raw_static("e.id")

      expect do
        described_class.fragment("{} = {}", part)
      end.to raise_error(ClickHouse::SQL::Error, /2 anonymous \{\} slots but 1 positional fills/)

      expect do
        described_class.fragment("state = 'failed'", part)
      end.to raise_error(ClickHouse::SQL::Error, /0 anonymous \{\} slots but 1 positional fills/)
    end

    it "rejects runtime strings as anonymous fill values" do
      expect do
        described_class.fragment("{} = 1", "requests.is_deleted")
      end.to raise_error(ClickHouse::SQL::Error, /Anonymous fragment slot \{\} requires a SQL fragment, got String/)
    end

    it "accepts a positional bindings hash alongside positional fills" do
      part = described_class.raw_static("r.id")
      fragment = described_class.fragment("{} = {id:UUID}", part, { id: uuid })

      expect(fragment.to_sql).to eq("r.id = {id:UUID}")
      expect(fragment.placeholders).to eq(id: uuid)
    end

    it "rejects nested fragment placeholders with conflicting values" do
      inner = described_class.fragment("{x:String} = state", x: "inner")
      outer = described_class.fragment("{x:String} = path AND {nested}", x: "outer", nested: inner)

      expect { outer.placeholders }.to raise_error(ClickHouse::SQL::Error, /mismatching values for the 'x' placeholder/)
    end

    it "dedupes nested fragment placeholders with matching values" do
      inner = described_class.fragment("{x:String} = state", x: "same")
      outer = described_class.fragment("{x:String} = path AND {nested}", x: "same", nested: inner)

      expect(outer.placeholders).to eq(x: "same")
    end

    it "rejects nested fragment placeholders with conflicting types" do
      inner = described_class.fragment("{x:UUID} = state", x: uuid)
      outer = described_class.fragment("{x:String} = path AND {nested}", x: "a", nested: inner)

      expect { outer.placeholder_types }.to raise_error(ClickHouse::SQL::Error, /mismatching types for the 'x' placeholder/)
    end

    it "sends one parameter for a repeated placeholder but redacts each occurrence" do
      fragment = described_class.fragment(
        "created_at <= {ts:DateTime} OR updated_at <= {ts:DateTime}",
        ts: "2026-07-01 00:00:00"
      )

      expect(fragment.placeholders).to eq(ts: "2026-07-01 00:00:00")
      expect(fragment.to_redacted_sql).to eq("created_at <= $1 OR updated_at <= $2")
    end

    it "rejects nil fragment slot values" do
      expect do
        described_class.fragment("{condition} AND status = {status:String}", condition: nil, status: "failed")
      end.to raise_error(ClickHouse::SQL::Error, /Fragment slot \{condition\} requires a SQL fragment, got NilClass/)
    end

    it "rejects missing placeholder values" do
      expect do
        described_class.fragment("id = {id:UUID}")
      end.to raise_error(ClickHouse::SQL::Error, /Missing ClickHouse placeholder values: id/)
    end

    it "rejects unused placeholder values" do
      expect do
        described_class.fragment("id = {id:UUID}", id: uuid, other: uuid)
      end.to raise_error(ClickHouse::SQL::Error, /Unused ClickHouse placeholder values: other/)
    end

    it "rejects duplicate placeholders with conflicting types" do
      expect do
        described_class.fragment("id = {id:UUID} OR id = {id:String}", id: uuid)
      end.to raise_error(ClickHouse::SQL::Error, /mismatching types for the 'id' placeholder/)
    end

    it "rejects placeholders used as both typed bind values and fragment slots" do
      expect do
        described_class.fragment("id = {id:UUID} AND {id}", id: uuid)
      end.to raise_error(ClickHouse::SQL::Error, /cannot be both typed values and fragment slots: id/)
    end

    it "rejects unsafe identifier values" do
      expect do
        described_class.fragment("attributes.{attribute_key:Identifier}", attribute_key: "foo; DROP TABLE endpoints")
      end.to raise_error(ClickHouse::SQL::Error, /Identifier placeholder requires a safe identifier/)
    end

    it "truncates oversized values in placeholder validation errors" do
      # Caller-bug errors land in error trackers; whole user-supplied values
      # (attribute values, endpoint names) must not travel with them.
      long = "not-a-uuid #{"x" * 100}"

      expect do
        described_class.fragment("id = {id:UUID}", id: long)
      end.to raise_error(ClickHouse::SQL::Error) do |error|
        expect(error.message).to include("truncated String")
        expect(error.message).not_to include(long)
      end
    end

    it "truncates oversized values in mismatching-value errors" do
      first = "first #{"a" * 100}"
      second = "second #{"b" * 100}"
      inner = described_class.fragment("{x:String} = state", x: first)
      outer = described_class.fragment("{x:String} = path AND {nested}", x: second, nested: inner)

      expect do
        outer.placeholders
      end.to raise_error(ClickHouse::SQL::Error) do |error|
        expect(error.message).to include("mismatching values for the 'x' placeholder")
        expect(error.message).not_to include(first)
        expect(error.message).not_to include(second)
      end
    end

    it "rejects subtly malformed identifier values" do
      expect do
        described_class.fragment("attributes.{attribute_key:Identifier}", attribute_key: "http..method")
      end.to raise_error(ClickHouse::SQL::Error, /Identifier placeholder requires a safe identifier/)

      expect do
        described_class.fragment("attributes.{attribute_key:Identifier}", attribute_key: "1method")
      end.to raise_error(ClickHouse::SQL::Error, /Identifier placeholder requires a safe identifier/)
    end

    it "keeps malicious string bind values out of rendered SQL" do
      value = "GET' OR 1 = 1; DROP TABLE requests; --"
      fragment = described_class.fragment("method = {method:String}", method: value)

      expect(fragment.to_sql).to eq("method = {method:String}")
      expect(fragment.to_sql).not_to include(value)
      expect(fragment.to_redacted_sql).to eq("method = $1")
      expect(fragment.to_redacted_sql).not_to include(value)
      expect(fragment.placeholders).to eq(method: value)
    end

    it "rejects values that do not match the declared ClickHouse type" do
      expect do
        described_class.fragment("endpoint_id IN {endpoint_ids:Array(UUID)}", endpoint_ids: ["not-a-uuid"])
      end.to raise_error(ClickHouse::SQL::Error, /UUID-shaped/)
    end

    it "rejects non-arrays for Array placeholders" do
      expect do
        described_class.fragment("endpoint_id IN {endpoint_ids:Array(UUID)}", endpoint_ids: uuid)
      end.to raise_error(ClickHouse::SQL::Error, /Array placeholder requires an Array/)
    end

    it "only allows nil for Nullable placeholders" do
      nullable = described_class.fragment("name = {name:Nullable(String)}", name: nil)

      expect(nullable.placeholders).to eq(name: nil)

      expect do
        described_class.fragment("name = {name:String}", name: nil)
      end.to raise_error(ClickHouse::SQL::Error, /String placeholder does not accept nil/)
    end

    it "allows nil through LowCardinality wrappers with a Nullable inner type" do
      fragment = described_class.fragment("status = {status:LowCardinality(Nullable(String))}", status: nil)

      expect(fragment.placeholders).to eq(status: nil)

      expect do
        described_class.fragment("status = {status:LowCardinality(String)}", status: nil)
      end.to raise_error(ClickHouse::SQL::Error, /LowCardinality\(String\) placeholder does not accept nil/)
    end

    it "normalizes zoned times to UTC before formatting DateTime64 values" do
      fragment = described_class.fragment(
        "timestamp >= {ts:DateTime64(3)}",
        ts: Time.new(2026, 7, 1, 12, 0, 0, "+10:00")
      )

      expect(fragment.placeholders).to eq(ts: "2026-07-01 02:00:00.000")
    end

    it "normalizes ActiveSupport TimeWithZone values to UTC when supplied by the host" do
      source = <<~'RUBY'
        require "active_support"
        require "active_support/time"
        require "clickhouse/sql"

        melbourne = Time.utc(2026, 7, 1, 2, 30, 0).in_time_zone("Australia/Melbourne")
        fragment = ClickHouse::SQL.fragment("timestamp >= {ts:DateTime64(6)}", ts: melbourne)

        abort fragment.placeholders.inspect unless fragment.placeholders == { ts: "2026-07-01 02:30:00.000000" }
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

    it "normalizes zoned times to UTC for DateTime and unformatted DateTime64 placeholders" do
      zoned = Time.new(2026, 7, 1, 12, 0, 0, "+10:00")

      datetime = described_class.fragment("timestamp >= {ts:DateTime}", ts: zoned)
      expect(datetime.placeholders.fetch(:ts)).to eq(Time.utc(2026, 7, 1, 2, 0, 0))
      expect(datetime.placeholders.fetch(:ts)).to be_utc

      datetime64 = described_class.fragment("timestamp >= {ts:DateTime64}", ts: zoned)
      expect(datetime64.placeholders.fetch(:ts)).to be_utc
    end

    it "rejects time values for placeholders declaring a non-UTC timezone" do
      expect do
        described_class.fragment(
          "timestamp >= {ts:DateTime64(3, 'Australia/Melbourne')}",
          ts: Time.utc(2026, 7, 1)
        )
      end.to raise_error(ClickHouse::SQL::Error, /non-UTC timezone/)
    end

    it "accepts pre-formatted strings for placeholders declaring a non-UTC timezone" do
      fragment = described_class.fragment(
        "timestamp >= {ts:DateTime64(3, 'Australia/Melbourne')}",
        ts: "2026-07-01 12:00:00.000"
      )

      expect(fragment.placeholders).to eq(ts: "2026-07-01 12:00:00.000")
    end

    it "accepts time values for placeholders declaring the UTC timezone" do
      fragment = described_class.fragment(
        "timestamp >= {ts:DateTime64(3, 'UTC')}",
        ts: Time.new(2026, 7, 1, 12, 0, 0, "+10:00")
      )

      expect(fragment.placeholders).to eq(ts: "2026-07-01 02:00:00.000")
    end

    it "accepts numeric DateTime64 values for epoch-based ClickHouse binds" do
      fragment = described_class.fragment(
        "received_at IN ({timestamps:Array(DateTime64)})",
        timestamps: [1_786_146_014_123]
      )

      expect(fragment.placeholders).to eq(timestamps: [1_786_146_014_123])
    end

    it "validates integer placeholder ranges" do
      expect do
        described_class.fragment("LIMIT {limit:UInt16}", limit: 100_000)
      end.to raise_error(ClickHouse::SQL::Error, /outside 0\.\.65535/)

      expect do
        described_class.fragment("LIMIT {limit:UInt16}", limit: -1)
      end.to raise_error(ClickHouse::SQL::Error, /outside 0\.\.65535/)
    end

    it "normalizes integer strings for integer placeholders" do
      fragment = described_class.fragment("count = {count:UInt64}", count: "2")

      expect(fragment.placeholders).to eq(count: 2)
    end

    it "rejects non-finite float placeholder values" do
      expect do
        described_class.fragment("score > {score:Float64}", score: Float::INFINITY)
      end.to raise_error(ClickHouse::SQL::Error, /must be finite/)

      expect do
        described_class.fragment("score > {score:Float64}", score: Float::NAN)
      end.to raise_error(ClickHouse::SQL::Error, /must be finite/)
    end

    it "rejects runtime strings as fragment slot values" do
      expect do
        described_class.fragment("ORDER BY {column}", column: "timestamp DESC")
      end.to raise_error(ClickHouse::SQL::Error, /requires a SQL fragment/)
    end

    it "rejects client query objects as internal fragment slot values" do
      client_query = Struct.new(:to_sql, :placeholders).new("SELECT 1", {})

      expect do
        described_class.fragment("id IN ({client_query})", client_query:)
      end.to raise_error(ClickHouse::SQL::Error, /requires a SQL fragment/)
    end

    it "rejects blank fragments rather than producing empty SQL" do
      expect do
        described_class.fragment("\u00a0")
      end.to raise_error(ClickHouse::SQL::Error, /Empty SQL fragment given/)
    end
  end

  describe "combinators" do
    it "joins present fragments with boolean operators" do
      fragment = described_class.and([
        described_class.fragment("id = {id:UUID}", id: uuid),
        nil,
        described_class.fragment("status = {status:String}", status: "failed")
      ])

      expect(fragment.to_sql).to eq("(id = {id:UUID}) AND (status = {status:String})")
      expect(fragment.placeholders).to eq(id: uuid, status: "failed")
    end

    it "parenthesizes OR-joined fragments so nested ANDs cannot capture the clause" do
      fragment = described_class.or([
        described_class.fragment("status = {failed:String} AND retry_count = 0", failed: "failed"),
        nil,
        "status = 'skipped'"
      ])

      expect(fragment.to_sql).to eq("(status = {failed:String} AND retry_count = 0) OR (status = 'skipped')")
      expect(fragment.placeholders).to eq(failed: "failed")
    end

    it "returns nil when no fragments are present" do
      expect(described_class.and([])).to be_nil
      expect(described_class.and([nil, nil])).to be_nil
      expect(described_class.or([])).to be_nil
      expect(described_class.csv([nil])).to be_nil
    end

    it "joins fragments with commas without parenthesizing" do
      fragment = described_class.csv([
        "id",
        nil,
        described_class.fragment("attributes.{attribute_key:Identifier}", attribute_key: "http.method"),
      ])

      expect(fragment.to_sql).to eq("id, attributes.{attribute_key:Identifier}")
      expect(fragment.placeholders).to eq(attribute_key: "http.method")
    end

    it "wraps a fragment in parentheses" do
      fragment = described_class.parens(
        described_class.fragment("status = {status:String}", status: "failed")
      )

      expect(fragment.to_sql).to eq("(status = {status:String})")
      expect(fragment.placeholders).to eq(status: "failed")
    end

    it "builds a trusted star expression" do
      expect(described_class.star.to_sql).to eq("*")
      expect(described_class.star.placeholders).to eq({})
    end

    it "builds generated placeholder lists" do
      fragment = described_class.bind_list(:path, ["/users", "/orders"], type: "String")

      expect(fragment.to_sql).to eq("{path_0:String}, {path_1:String}")
      expect(fragment.placeholders).to eq(path_0: "/users", path_1: "/orders")
    end

    it "can build compact generated placeholder lists for large IN clauses" do
      values = 37.times.map { |index| "/resources/#{index}" }
      fragment = described_class.bind_list(:t, values, type: "String", compact: true)

      expect(fragment.to_sql).to start_with("{t0:String}, {t1:String}, {t2:String}")
      expect(fragment.to_sql).to end_with("{tz:String}, {t10:String}")
      expect(fragment.placeholders.fetch(:t0)).to eq("/resources/0")
      expect(fragment.placeholders.fetch(:tz)).to eq("/resources/35")
      expect(fragment.placeholders.fetch(:t10)).to eq("/resources/36")
    end

    it "rejects empty bind lists with a clear error" do
      expect do
        described_class.bind_list(:file, [], type: "String")
      end.to raise_error(ClickHouse::SQL::Error, /bind_list requires at least one value/)
    end

    it "rejects generated bind prefixes that could break placeholder syntax" do
      expect do
        described_class.bind_list("path_0:String} OR 1 = 1 --", ["/users"], type: "String")
      end.to raise_error(ClickHouse::SQL::Error, /Generated bind prefix must be a simple identifier/)
    end

    it "rejects generated bind types that could break placeholder syntax" do
      expect do
        described_class.bind_list(:id, [1], type: "UInt64}) OR 1 = 1 --")
      end.to raise_error(ClickHouse::SQL::Error, /Generated bind type must not be blank or contain braces/)

      expect do
        described_class.bind_list(:id, [1], type: "Nullable({x:String})")
      end.to raise_error(ClickHouse::SQL::Error, /Generated bind type must not be blank or contain braces/)

      expect do
        described_class.bind_list(:id, [1], type: "")
      end.to raise_error(ClickHouse::SQL::Error, /Generated bind type must not be blank or contain braces/)
    end
  end

  describe ".select" do
    it "renders a clause-oriented SELECT query" do
      query = described_class
        .select(
          "r.id",
          "r.timestamp",
          p95_duration: described_class.raw_static("quantileDD(0.95)(r.duration)")
        )
        .from("requests", as: "r")
        .left_join(
          "endpoints",
          as: "e",
          final: true,
          on: [
            "e.id = r.endpoint_id",
            "e.organization_id = r.organization_id",
          ]
        )
        .where("r.organization_id = {organization_id:UUID}", organization_id: uuid)
        .where("r.endpoint_id IN {endpoint_ids:Array(UUID)}", endpoint_ids: [uuid])
        .group_by("r.id", "r.timestamp")
        .having("count() > {minimum_count:UInt16}", minimum_count: 1)
        .order_by("r.timestamp DESC")
        .limit("{limit:UInt32}", limit: 50)
        .offset("{offset:UInt32}", offset: 10)
        .setting("max_execution_time", 30)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          r.id,
          r.timestamp,
          quantileDD(0.95)(r.duration) AS p95_duration
        FROM requests AS r
        LEFT JOIN endpoints FINAL AS e ON (e.id = r.endpoint_id) AND (e.organization_id = r.organization_id)
        WHERE
          (r.organization_id = {organization_id:UUID})
          AND (r.endpoint_id IN {endpoint_ids:Array(UUID)})
        GROUP BY r.id, r.timestamp
        HAVING
          (count() > {minimum_count:UInt16})
        ORDER BY r.timestamp DESC
        LIMIT {limit:UInt32}
        OFFSET {offset:UInt32}
        SETTINGS max_execution_time = 30
      SQL
      expect(query.placeholders).to eq(
        organization_id: uuid,
        endpoint_ids: [uuid],
        minimum_count: 1,
        limit: 50,
        offset: 10
      )
      expect(query.to_redacted_sql).to include("r.organization_id = $1")
      expect(query.to_redacted_sql).to include("LIMIT $4")
      expect(query.to_redacted_sql).to include("SETTINGS max_execution_time = $6")
    end

    it "renders SELECT DISTINCT when distinct is set" do
      query = described_class
        .select(value: described_class.raw_static("requests.attributes.{attribute_key:Identifier}"))
        .distinct
        .from("requests")
        .limit("{limit:Integer}", limit: 10)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT DISTINCT
          requests.attributes.{attribute_key:Identifier} AS value
        FROM requests
        LIMIT {limit:Integer}
      SQL
    end

    it "renders FROM with FINAL before the table alias" do
      query = described_class
        .select("id")
        .from("requests", as: "r", final: true)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          id
        FROM requests FINAL AS r
      SQL
    end

    it "renders subquery FROM clauses with a required validated string alias" do
      subquery = described_class
        .select("id")
        .from("requests")
        .where("endpoint_id = {endpoint_id:UUID}", endpoint_id: uuid)

      query = described_class
        .select("filtered.id")
        .from_subquery(subquery, as: "filtered")

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          filtered.id
        FROM (SELECT
          id
        FROM requests
        WHERE
          (endpoint_id = {endpoint_id:UUID})) AS filtered
      SQL
      expect(query.placeholders).to eq(endpoint_id: uuid)

      expect(
        described_class.select("id").from_subquery(subquery, as: :filtered).to_sql
      ).to include("AS filtered")

      expect do
        described_class
          .select("id")
          .from_subquery(subquery, as: "f; DROP TABLE requests; --")
          .to_sql
      end.to raise_error(ClickHouse::SQL::Error, /SQL alias must be a simple identifier/)
    end

    it "uses an unaliased table handle's qualifier as a subquery alias" do
      filtered = described_class.table("filtered")
      subquery = described_class
        .select("id")
        .from("requests")
        .where("endpoint_id = {endpoint_id:UUID}", endpoint_id: uuid)

      query = described_class
        .select(filtered[:id])
        .from_subquery(subquery, as: filtered)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          filtered.id
        FROM (SELECT
          id
        FROM requests
        WHERE
          (endpoint_id = {endpoint_id:UUID})) AS filtered
      SQL
      expect(query.placeholders).to eq(endpoint_id: uuid)
      expect(query.placeholder_types).to eq(endpoint_id: "UUID")
      expect(query.to_redacted_sql).to include("endpoint_id = $1")
    end

    it "uses an aliased table handle's qualifier as a subquery alias" do
      filtered = described_class.table("filtered_rows", as: "filtered")
      subquery = described_class.select("id").from("requests")

      query = described_class
        .select(filtered[:id])
        .from_subquery(subquery, as: filtered)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          filtered.id
        FROM (SELECT
          id
        FROM requests) AS filtered
      SQL
    end

    it "renders INNER JOIN by default and via inner_join" do
      query = described_class
        .select("r.id")
        .from("requests", as: "r")
        .join("endpoints", as: "e", on: "e.id = r.endpoint_id")
        .inner_join("organizations", as: "o", on: "o.id = r.organization_id")

      expect(query.to_sql).to include("INNER JOIN endpoints AS e ON (e.id = r.endpoint_id)")
      expect(query.to_sql).to include("INNER JOIN organizations AS o ON (o.id = r.organization_id)")
    end

    it "renders pre-rendered JOIN fragments via joins" do
      join = described_class.fragment(
        "LEFT JOIN endpoints AS e ON e.id = r.endpoint_id AND e.path = {path:String}",
        path: "/users"
      )
      query = described_class
        .select("r.id")
        .from("requests", as: "r")
        .joins(join, nil)

      expect(query.to_sql).to include("LEFT JOIN endpoints AS e ON e.id = r.endpoint_id AND e.path = {path:String}")
      expect(query.placeholders).to eq(path: "/users")
    end

    it "compacts nil conditions so conditional filters compose" do
      maybe_filter = nil
      query = described_class
        .select("id")
        .from("requests")
        .where("organization_id = {organization_id:UUID}", organization_id: uuid)
        .where(maybe_filter)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          id
        FROM requests
        WHERE
          (organization_id = {organization_id:UUID})
      SQL
    end

    it "fills anonymous {} slots in WHERE conditions from positional arguments" do
      column = described_class.raw_static("requests.organization_id")

      query = described_class
        .select("id")
        .from("requests")
        .where("{} = {organization_id:UUID}", column, organization_id: uuid)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          id
        FROM requests
        WHERE
          (requests.organization_id = {organization_id:UUID})
      SQL
      expect(query.placeholders).to eq(organization_id: uuid)
    end

    it "appends arrays of conditions AND-joined" do
      query = described_class
        .select("id")
        .from("requests")
        .where([
          described_class.fragment("organization_id = {organization_id:UUID}", organization_id: uuid),
          "state = 'failed'",
          nil,
        ])

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          id
        FROM requests
        WHERE
          (organization_id = {organization_id:UUID})
          AND (state = 'failed')
      SQL
    end

    it "rejects multiple positional conditions now that extra positionals are anonymous fills" do
      expect do
        described_class
          .select("id")
          .from("requests")
          .where("a = {a:UUID}", "b = 1", a: uuid)
      end.to raise_error(ClickHouse::SQL::Error, /0 anonymous \{\} slots but 1 positional fills/)
    end

    it "rejects positional fills and keyword bindings for arrays of conditions" do
      part = described_class.raw_static("e.id")

      expect do
        described_class.select("id").from("requests").where(["a = 1"], part)
      end.to raise_error(ClickHouse::SQL::Error, /require a single SQL string, got Array/)

      expect do
        described_class.select("id").from("requests").where(["a = {a:UUID}"], a: uuid)
      end.to raise_error(ClickHouse::SQL::Error, /require a single SQL string, got Array/)

      expect do
        described_class.select("id").from("requests").where(a: uuid)
      end.to raise_error(ClickHouse::SQL::Error, /require a single SQL string, got NilClass/)
    end

    it "rejects bare integers for LIMIT and OFFSET" do
      expect do
        described_class.select("id").from("requests").limit(50)
      end.to raise_error(ClickHouse::SQL::Error, /Expected a SQL fragment or trusted SQL string, got Integer/)

      expect do
        described_class.select("id").from("requests").offset(10)
      end.to raise_error(ClickHouse::SQL::Error, /Expected a SQL fragment or trusted SQL string, got Integer/)
    end

    it "renders WITH fragments and subquery FROM clauses" do
      subquery = described_class
        .select("id")
        .from("requests")
        .where("endpoint_id = {endpoint_id:UUID}", endpoint_id: uuid)

      query = described_class
        .select("id")
        .with("filtered AS ({subquery})", subquery:)
        .from("filtered")

      expect(query.to_sql).to eq(<<~SQL.strip)
        WITH
          filtered AS (SELECT
          id
        FROM requests
        WHERE
          (endpoint_id = {endpoint_id:UUID}))
        SELECT
          id
        FROM filtered
      SQL
      expect(query.placeholders).to eq(endpoint_id: uuid)
    end

    it "renders a CTE named by its table handle and composes its placeholders" do
      filtered = described_class.table("filtered")
      subquery = described_class
        .select("id")
        .from("requests")
        .where("endpoint_id = {endpoint_id:UUID}", endpoint_id: uuid)

      query = described_class
        .select(filtered[:id])
        .with_cte(filtered, subquery)
        .from(filtered)

      expect(query.to_sql).to eq(<<~SQL.strip)
        WITH
          filtered AS (SELECT
          id
        FROM requests
        WHERE
          (endpoint_id = {endpoint_id:UUID}))
        SELECT
          filtered.id
        FROM filtered
      SQL
      expect(query.placeholders).to eq(endpoint_id: uuid)
      expect(query.placeholder_types).to eq(endpoint_id: "UUID")
      expect(query.to_redacted_sql).to include("endpoint_id = $1")
    end

    it "uses an aliased table handle's name for the CTE and its alias for references" do
      filtered = described_class.table("filtered_rows", as: "filtered")
      subquery = described_class.select("id").from("requests")

      query = described_class
        .select(filtered[:id])
        .with_cte(filtered, subquery)
        .from(filtered)

      expect(query.to_sql).to eq(<<~SQL.strip)
        WITH
          filtered_rows AS (SELECT
          id
        FROM requests)
        SELECT
          filtered.id
        FROM filtered_rows AS filtered
      SQL
    end

    it "requires a table handle with a simple CTE name" do
      subquery = described_class.select("id").from("requests")

      expect do
        described_class.select("id").with_cte("filtered", subquery)
      end.to raise_error(ClickHouse::SQL::Error, /CTE handle must be a table handle/)

      expect do
        described_class.select("id").with_cte(described_class.table("analytics.filtered"), subquery)
      end.to raise_error(ClickHouse::SQL::Error, /SQL alias must be a simple identifier/)
    end

    it "raises when composed clauses reuse a placeholder name with different values" do
      query = described_class
        .select("id")
        .from("requests")
        .where("organization_id = {id:UUID}", id: uuid)
        .where("endpoint_id = {id:UUID}", id: "018f3f4a-8f58-7c3f-8b5c-0f6f30fd9ed2")

      expect do
        query.placeholders
      end.to raise_error(ClickHouse::SQL::Error, /mismatching values for the 'id' placeholder/)
    end

    it "raises when composed clauses reuse a placeholder name with different types" do
      query = described_class
        .select("id")
        .from("requests")
        .where("organization_id = {id:UUID}", id: uuid)
        .where("name = {id:String}", id: uuid)

      expect do
        query.placeholder_types
      end.to raise_error(ClickHouse::SQL::Error, /mismatching types for the 'id' placeholder/)
    end

    it "rejects malicious SQL aliases" do
      query = described_class
        .select("id", "value; DROP TABLE requests; --": "duration")
        .from("requests")

      expect do
        query.to_sql
      end.to raise_error(ClickHouse::SQL::Error, /SQL alias must be a simple identifier/)
    end

    it "rejects invalid table aliases" do
      query = described_class
        .select("id")
        .from("requests", as: "r; DROP TABLE requests; --")

      expect do
        query.to_sql
      end.to raise_error(ClickHouse::SQL::Error, /SQL alias must be a simple identifier/)
    end

    it "rejects joins without ON conditions" do
      expect do
        described_class
          .select("id")
          .from("requests")
          .left_join("endpoints", on: [])
      end.to raise_error(ClickHouse::SQL::Error, /JOIN requires at least one ON condition/)
    end

    it "rejects incomplete SELECT queries" do
      expect do
        described_class.select("id").to_sql
      end.to raise_error(ClickHouse::SQL::Error, /SELECT requires a FROM clause/)

      expect do
        ClickHouse::SQL::SelectQuery.new.from("requests").to_sql
      end.to raise_error(ClickHouse::SQL::Error, /SELECT requires at least one selected expression/)
    end

    it "converts to an immutable query object satisfying the client query protocol" do
      query = described_class.select("id").from("requests")
      compiled = query.to_query

      expect(query).to be_a(ClickHouse::SQL::Part)
      expect(compiled).to be_a(ClickHouse::SQL::Query)
      expect(compiled).to be_a(ClickHouse::SQL::Part)
      expect(compiled).to respond_to(:to_sql)
      expect(compiled).to respond_to(:placeholders)
      expect(compiled).to be_frozen
      expect(compiled.placeholders).to be_frozen
      expect(compiled.placeholder_types).to be_frozen
    end

    it "compiles nil values bound to Nullable placeholder types" do
      query = described_class
        .select("id")
        .from("requests")
        .where("path = {path:Nullable(String)}", path: nil)
        .where("headers = {headers:Array(Nullable(String))}", headers: ["a", nil])
        .to_query

      expect(query.placeholders).to eq(path: nil, headers: ["a", nil])
    end

    it "compiles nil values bound to LowCardinality(Nullable(...)) placeholder types" do
      query = described_class
        .select("id")
        .from("requests")
        .where("status = {status:LowCardinality(Nullable(String))}", status: nil)
        .where("headers = {headers:Array(LowCardinality(Nullable(String)))}", headers: ["a", nil])
        .to_query

      expect(query.placeholders).to eq(status: nil, headers: ["a", nil])
    end

    it "rejects nil values bound to non-Nullable placeholder types when binding" do
      # ClickHouse cannot represent NULL in a non-Nullable parameter, and for
      # a String placeholder it silently parses NULL as an empty string.
      expect do
        described_class
          .select("id")
          .from("requests")
          .where("path = {path:String}", path: nil)
      end.to raise_error(ClickHouse::SQL::Error, /String placeholder does not accept nil/)

      expect do
        described_class
          .select("id")
          .from("requests")
          .where("headers IN {headers:Array(String)}", headers: ["a", nil])
      end.to raise_error(ClickHouse::SQL::Error, /String placeholder does not accept nil/)
    end

    it "rejects nils that escape binding validation when compiling" do
      # Placeholder types without binding validation (such as Map) pass
      # values through untouched, so the compiled query is the final gate
      # keeping nils away from non-Nullable placeholders.
      expect do
        described_class
          .select("id")
          .from("requests")
          .where("meta = {meta:Map(String,String)}", meta: { "key" => nil })
          .to_query
      end.to raise_error(ClickHouse::SQL::Error, /nil element bound to non-Nullable placeholder \{meta:Map\(String,String\)\}/)
    end

    it "copies mutable bind values when compiling" do
      endpoint_ids = [uuid]
      method = +"GET"
      query = described_class
        .select("id")
        .from("requests")
        .where("endpoint_id IN {endpoint_ids:Array(UUID)}", endpoint_ids:)
        .where("method = {method:String}", method:)
        .to_query

      endpoint_ids << "018f3f4a-8f58-7c3f-8b5c-0f6f30fd9ed2"
      method.replace("mutated")

      expect(query.placeholders).to eq(endpoint_ids: [uuid], method: "GET")
      expect(query.placeholders.fetch(:endpoint_ids)).to be_frozen
      expect(query.placeholders.fetch(:method)).to be_frozen
    end

    it "numbers redacted bind markers left-to-right across all clauses" do
      subquery = described_class
        .select("id")
        .from("requests")
        .where("endpoint_id = {endpoint_id:UUID}", endpoint_id: uuid)

      query = described_class
        .select("id", failed: described_class.fragment("countIf(status = {failed_status:String})", failed_status: "failed"))
        .with("filtered AS ({subquery})", subquery:)
        .from("filtered")
        .where("organization_id = {organization_id:UUID}", organization_id: uuid)
        .having("count() > {minimum_count:UInt16}", minimum_count: 1)
        .limit("{limit:UInt32}", limit: 10)
        .offset("{offset:UInt32}", offset: 5)
        .setting("max_execution_time", 30)

      expect(query.to_redacted_sql).to eq(<<~SQL.strip)
        WITH
          filtered AS (SELECT
          id
        FROM requests
        WHERE
          (endpoint_id = $1))
        SELECT
          id,
          countIf(status = $2) AS failed
        FROM filtered
        WHERE
          (organization_id = $3)
        HAVING
          (count() > $4)
        LIMIT $5
        OFFSET $6
        SETTINGS max_execution_time = $7
      SQL
    end

    it "mutates and returns self from clause methods" do
      query = described_class.select("id")

      expect(query.select("timestamp")).to be(query)
      expect(query.from("requests")).to be(query)
      expect(query.where("endpoint_id = {endpoint_id:UUID}", endpoint_id: uuid)).to be(query)
      expect(query.group_by("id")).to be(query)
      expect(query.having("count() > 1")).to be(query)
      expect(query.order_by("timestamp DESC")).to be(query)
      expect(query.limit("10")).to be(query)
      expect(query.offset("5")).to be(query)
      expect(query.setting("max_execution_time", 30)).to be(query)
    end

    it "keeps compiled queries unaffected by later builder mutation" do
      query = described_class
        .select("id")
        .from("requests")
        .where("organization_id = {organization_id:UUID}", organization_id: uuid)
      compiled = query.to_query

      query.where("status = {status:String}", status: "failed")

      expect(compiled.to_sql).not_to include("{status:String}")
      expect(compiled.placeholders.keys).to eq([:organization_id])

      recompiled = query.to_query
      expect(recompiled.to_sql).to include("{status:String}")
      expect(recompiled.placeholders.keys).to eq([:organization_id, :status])
    end

    it "returns the compiled redacted template unchanged when there are no binds" do
      compiled = described_class.select("id").from("requests").to_query
      bind_index_manager = ClickHouse::SQL::BindIndexManager.new

      expect(compiled.to_redacted_sql(bind_index_manager)).to eq(compiled.to_sql)
      expect(bind_index_manager.next_bind_str).to eq("$1")
    end

    it "renders compiled query redaction with the caller's bind index manager" do
      query = described_class
        .select("id")
        .from("requests")
        .where("endpoint_id IN {endpoint_ids:Array(UUID)}", endpoint_ids: [uuid])
        .where("timestamp >= {timestamp:DateTime64(6)}", timestamp: Time.utc(2026, 7, 1, 12, 13, 14, 123_456))
        .setting("max_execution_time", 30)

      bind_index_manager = ClickHouse::SQL::BindIndexManager.new
      expect(bind_index_manager.next_bind_str).to eq("$1")
      expect(query.to_query.to_redacted_sql(bind_index_manager)).to eq(<<~SQL.strip)
        SELECT
          id
        FROM requests
        WHERE
          (endpoint_id IN $2)
          AND (timestamp >= $3)
        SETTINGS max_execution_time = $4
      SQL
    end
  end

  describe ".setting" do
    it "renders validated inline setting literals because ClickHouse does not support parameters in SETTINGS" do
      query = described_class
        .select("id")
        .from("requests")
        .setting("max_execution_time", 10)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          id
        FROM requests
        SETTINGS max_execution_time = 10
      SQL
      expect(query.placeholders).to eq({})
      expect(query.to_redacted_sql).to include("SETTINGS max_execution_time = $1")
    end

    it "accepts static SETTINGS fragments and renders multiple settings comma-joined" do
      query = described_class
        .select("id")
        .from("requests")
        .settings("join_use_nulls = 1")
        .setting("max_execution_time", 30)

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          id
        FROM requests
        SETTINGS join_use_nulls = 1, max_execution_time = 30
      SQL
    end

    it "renders boolean setting values as 1 and 0" do
      expect(described_class.setting("allow_experimental_analyzer", true).to_sql).to eq("allow_experimental_analyzer = 1")
      expect(described_class.setting("allow_experimental_analyzer", false).to_sql).to eq("allow_experimental_analyzer = 0")
    end

    it "rejects unsupported setting value types" do
      expect do
        described_class.setting("max_execution_time", nil)
      end.to raise_error(ClickHouse::SQL::Error, /setting value must be a String, Integer, Float, or boolean/)

      expect do
        described_class.setting("max_execution_time", [30])
      end.to raise_error(ClickHouse::SQL::Error, /setting value must be a String, Integer, Float, or boolean/)
    end

    it "quotes and escapes string setting values before rendering them inline" do
      setting = described_class.setting("log_comment", "safe'\\value")

      expect(setting.to_sql).to eq("log_comment = 'safe\\'\\\\value'")
      expect(setting.to_redacted_sql).to eq("log_comment = $1")
    end

    it "rejects malicious setting names" do
      expect do
        described_class.setting("max_execution_time; DROP TABLE requests; --", 10)
      end.to raise_error(ClickHouse::SQL::Error, /setting name must be a simple identifier/)
    end

    it "rejects non-finite numeric setting values" do
      expect do
        described_class.setting("max_execution_time", Float::INFINITY)
      end.to raise_error(ClickHouse::SQL::Error, /setting value must be finite/)
    end

    it "rejects parameterized SETTINGS fragments so server-incompatible queries fail in unit tests" do
      expect do
        described_class
          .select("id")
          .from("requests")
          .settings("max_execution_time = {max_execution_time:UInt32}", max_execution_time: 10)
      end.to raise_error(ClickHouse::SQL::Error, /SETTINGS do not support query parameters/)

      expect do
        described_class
          .select("id")
          .from("requests")
          .settings(described_class.fragment("max_execution_time = {max_execution_time:UInt32}", max_execution_time: 10))
      end.to raise_error(ClickHouse::SQL::Error, /SETTINGS do not support query parameters/)
    end
  end

  describe ".table" do
    it "qualifies column references with the table name" do
      requests = described_class.table("requests")

      expect(requests[:timestamp].to_sql).to eq("requests.timestamp")
      expect(requests["metadata.trace.id"].to_sql).to eq("requests.metadata.trace.id")
    end

    it "qualifies column references with the alias when present" do
      requests = described_class.table("requests", as: "r")

      expect(requests.qualifier).to eq("r")
      expect(requests[:timestamp].to_sql).to eq("r.timestamp")
    end

    it "builds many qualified column references at once" do
      requests = described_class.table("requests", as: "r")

      expect(requests.columns(:id, :timestamp).map(&:to_sql)).to eq(["r.id", "r.timestamp"])
      expect(requests.columns(%i[id timestamp]).map(&:to_sql)).to eq(["r.id", "r.timestamp"])

      expect do
        requests.columns(:id, "timestamp; --")
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)
    end

    it "selects column lists with or without a splat" do
      requests = described_class.table("requests")

      query = described_class
        .select(requests.columns(:id, :timestamp), "count() AS total")
        .from(requests)
        .group_by(*requests.columns(:id, :timestamp))

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          requests.id,
          requests.timestamp,
          count() AS total
        FROM requests
        GROUP BY requests.id, requests.timestamp
      SQL
    end

    it "rejects unsafe table names, aliases, and column names" do
      expect do
        described_class.table("requests; DROP TABLE endpoints")
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)

      expect do
        described_class.table("requests", as: "r; --")
      end.to raise_error(ClickHouse::SQL::Error, /SQL alias/)

      expect do
        described_class.table("requests")["timestamp; --"]
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)

      expect do
        described_class.table("requests")["metadata..trace_id"]
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)
    end

    it "rejects identifiers containing hyphens, which read as comments or subtraction in SQL" do
      # Table handles interpolate Ruby-side into raw SQL with no quoting, so
      # `--` would comment out the rest of the rendered line.
      expect do
        described_class.table("requests")["metadata--x"]
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)

      expect do
        described_class.table("a-b")
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)
    end

    it "truncates oversized identifiers in table handle errors" do
      long = "bad-column #{"x" * 100}"

      expect do
        described_class.table("requests")[long]
      end.to raise_error(ClickHouse::SQL::Error) do |error|
        expect(error.message).to include("truncated String")
        expect(error.message).not_to include(long)
      end
    end

    it "rejects identifiers with leading or trailing dots" do
      expect do
        described_class.table("requests")["metadata."]
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)

      expect do
        described_class.table("requests")[".metadata"]
      end.to raise_error(ClickHouse::SQL::Error, /safe identifier/)
    end

    it "composes qualified columns into fragments as slots" do
      requests = described_class.table("requests", as: "r")
      fragment = described_class.fragment(
        "{ts} >= {from:DateTime64(6)}",
        ts: requests[:timestamp],
        from: Time.utc(2026, 7, 1)
      )

      expect(fragment.to_sql).to eq("r.timestamp >= {from:DateTime64(6)}")
      expect(fragment.to_redacted_sql).to eq("r.timestamp >= $1")
    end

    it "contributes its alias to FROM and JOIN clauses" do
      requests = described_class.table("requests", as: "r")
      endpoints = described_class.table("endpoints", as: "e")

      query = described_class
        .select(requests[:id], endpoints[:path])
        .from(requests, final: true)
        .left_join(
          endpoints,
          final: true,
          on: [
            described_class.fragment("{a} = {b}", a: endpoints[:id], b: requests[:endpoint_id]),
          ]
        )

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          r.id,
          e.path
        FROM requests FINAL AS r
        LEFT JOIN endpoints FINAL AS e ON (e.id = r.endpoint_id)
      SQL
    end

    it "renders unaliased handles without an alias clause" do
      requests = described_class.table("requests")
      endpoints = described_class.table("endpoints")

      query = described_class
        .select(requests[:id])
        .from(requests)
        .inner_join(endpoints, on: [described_class.fragment("{a} = {b}", a: endpoints[:id], b: requests[:endpoint_id])])

      expect(query.to_sql).to eq(<<~SQL.strip)
        SELECT
          requests.id
        FROM requests
        INNER JOIN endpoints ON (endpoints.id = requests.endpoint_id)
      SQL
    end

    it "rejects an explicit clause alias alongside a handle, even a matching one" do
      aliased = described_class.table("requests", as: "r")
      unaliased = described_class.table("requests")

      expect do
        described_class.select("id").from(aliased, as: "r")
      end.to raise_error(ClickHouse::SQL::Error, /table handle owns its alias/)

      expect do
        described_class.select("id").from(aliased, as: "other")
      end.to raise_error(ClickHouse::SQL::Error, /table handle owns its alias/)

      expect do
        described_class.select("id").from(unaliased, as: "e")
      end.to raise_error(ClickHouse::SQL::Error, /table handle owns its alias/)

      expect do
        described_class.select("id").from("dummy").join(aliased, as: "other", on: ["1 = 1"])
      end.to raise_error(ClickHouse::SQL::Error, /table handle owns its alias/)

      expect do
        described_class.left_join(unaliased, as: "r", on: ["1 = 1"])
      end.to raise_error(ClickHouse::SQL::Error, /table handle owns its alias/)
    end

    it "still allows aliasing a string table name at the clause" do
      expect(
        described_class.select("id").from("requests", as: "r").to_sql
      ).to include("FROM requests AS r")
    end
  end

  describe ".left_join" do
    it "builds a standalone JOIN clause appendable with #joins" do
      requests = described_class.table("requests")
      endpoints = described_class.table("endpoints")

      join = described_class.left_join(
        endpoints,
        final: true,
        on: [described_class.fragment("{a} = {b}", a: endpoints[:id], b: requests[:endpoint_id])]
      )

      query = described_class
        .select(requests[:id])
        .from(requests)
        .joins(join)

      expect(query.to_sql).to include(
        "LEFT JOIN endpoints FINAL ON (endpoints.id = requests.endpoint_id)"
      )
    end

    it "carries typed placeholders from ON conditions into the query" do
      join = described_class.left_join(
        "endpoints",
        on: [described_class.fragment("endpoints.state = {state:String}", state: "enabled")]
      )

      query = described_class.select("id").from("requests").joins(join)

      expect(query.placeholders).to eq(state: "enabled")
      expect(query.to_redacted_sql).to include("endpoints.state = $1")
    end
  end

  describe ".raw_static" do
    it "rejects blank raw SQL" do
      expect do
        described_class.raw_static("")
      end.to raise_error(ClickHouse::SQL::Error, /Empty SQL string given/)
    end

    it "renders literal braces untouched with no placeholders" do
      raw = described_class.raw_static("map['{key}']")

      expect(raw.to_sql).to eq("map['{key}']")
      expect(raw.to_redacted_sql).to eq("map['{key}']")
      expect(raw.placeholders).to eq({})
      expect(raw.placeholder_types).to eq({})
    end

    it "keeps literal braces untouched when nested in a fragment slot" do
      raw = described_class.raw_static("map['{key}']")
      fragment = described_class.fragment("{column} = {value:String}", column: raw, value: "x")

      expect(fragment.to_sql).to eq("map['{key}'] = {value:String}")
      expect(fragment.to_redacted_sql).to eq("map['{key}'] = $1")
      expect(fragment.placeholders).to eq(value: "x")
    end
  end

  describe ".unsafe_raw" do
    it "renders trusted SQL verbatim and records the reason" do
      raw = described_class.unsafe_raw("timestamp DESC", reason: "sort direction is validated upstream")

      expect(raw.to_sql).to eq("timestamp DESC")
      expect(raw.to_redacted_sql).to eq("timestamp DESC")
      expect(raw.unsafe_reason).to eq("sort direction is validated upstream")
    end

    it "requires a grep-able reason" do
      expect do
        described_class.unsafe_raw("timestamp DESC", reason: "")
      end.to raise_error(ClickHouse::SQL::Error, /requires a reason/)
    end
  end
end
