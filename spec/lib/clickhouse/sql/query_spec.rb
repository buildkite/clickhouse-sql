# frozen_string_literal: true

require "spec_helper"

require_relative "../../../../lib/clickhouse/sql"

RSpec.describe ClickHouse::SQL::Query do
  # The builder validates nil placeholder values at fragment construction, so
  # these defense-in-depth checks are only reachable by constructing a Query
  # directly — which other client code may do, since Query is the protocol
  # object accepted by ClickHouse::HTTPClient.
  describe "nil placeholder validation" do
    def query(placeholders:, placeholder_types:)
      described_class.new(
        sql: "SELECT path FROM endpoints WHERE path = {path:String}",
        redacted_sql: "SELECT path FROM endpoints WHERE path = ?",
        placeholders:,
        placeholder_types:
      )
    end

    it "rejects nil bound to a non-Nullable placeholder" do
      expect do
        query(placeholders: { path: nil }, placeholder_types: { path: "String" })
      end.to raise_error(ClickHouse::SQL::Error, /nil bound to non-Nullable placeholder \{path:String\}/)
    end

    it "rejects nil elements bound to a non-Nullable element type" do
      expect do
        query(placeholders: { path: ["a", nil] }, placeholder_types: { path: "Array(String)" })
      end.to raise_error(ClickHouse::SQL::Error, /nil element bound to non-Nullable placeholder/)
    end

    it "accepts nil for Nullable placeholder types" do
      expect(query(placeholders: { path: nil }, placeholder_types: { path: "Nullable(String)" }).placeholders).to eq(path: nil)
      expect(query(placeholders: { path: [nil] }, placeholder_types: { path: "Array(Nullable(String))" }).placeholders).to eq(path: [nil])
    end
  end
end
