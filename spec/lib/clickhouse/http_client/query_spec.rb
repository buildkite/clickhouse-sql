# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClickHouse::HTTPClient::Query do
  describe ".wrap" do
    it "wraps a SQL string with no placeholders" do
      query = described_class.wrap("SELECT 1")

      expect(query.sql).to eq("SELECT 1")
      expect(query.placeholders).to eq({})
    end

    it "passes an existing Query through by value" do
      original = described_class.new(sql: "SELECT {id:UInt64}", placeholders: { id: 1 })
      query = described_class.wrap(original)

      expect(query).to eq(original)
    end

    it "accepts any object honoring the query protocol" do
      duck = Struct.new(:to_sql, :placeholders).new("SELECT {id:UInt64}", { "id" => 42 })
      query = described_class.wrap(duck)

      expect(query.sql).to eq("SELECT {id:UInt64}")
      expect(query.placeholders).to eq({ id: 42 })
    end

    it "rejects objects without the query protocol" do
      expect {
        described_class.wrap(Object.new)
      }.to raise_error(ClickHouse::HTTPClient::QueryError, /responding to #to_sql and #placeholders/)
    end

    it "compiles builders through #to_query" do
      builder = ClickHouse::SQL.select("id").from("requests").where("id = {id:UInt64}", id: 1)

      query = described_class.wrap(builder)

      expect(query.sql).to eq(builder.to_sql)
      expect(query.placeholders).to eq(id: 1)
    end

    it "applies the builder's own validation via #to_query" do
      # A Map(String, String) value containing nil passes fragment-level
      # type validation (PlaceholderType doesn't inspect Map contents) and
      # is only caught by ClickHouse::SQL::Query's nil net during #to_query
      # — which used to be skipped when a builder was passed directly.
      builder = ClickHouse::SQL
        .select("id")
        .from("requests")
        .where("headers = {headers:Map(String, String)}", headers: { "accept" => nil })

      expect {
        described_class.wrap(builder)
      }.to raise_error(ClickHouse::SQL::Error, /nil element bound to non-Nullable placeholder/)
    end
  end

  it "rejects empty SQL" do
    expect {
      described_class.new(sql: "  ")
    }.to raise_error(ClickHouse::HTTPClient::QueryError, /Empty query/)
  end

  it "symbolizes placeholder keys and freezes state" do
    query = described_class.new(sql: "SELECT {a:UInt64}", placeholders: { "a" => 1 })

    expect(query.placeholders).to eq({ a: 1 })
    expect(query.sql).to be_frozen
    expect(query.placeholders).to be_frozen
  end

  it "responds to the query protocol itself" do
    query = described_class.new(sql: "SELECT 1")

    expect(query.to_sql).to eq("SELECT 1")
    expect(query.placeholders).to eq({})
  end
end
