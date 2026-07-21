# frozen_string_literal: true

module ClickHouse
  module SQL
    class Join
      include Part

      # Builds a rendered JOIN clause.
      #
      # @param table [String, Symbol, ClickHouse::SQL::Part] Trusted table expression.
      # @param type [String] JOIN type, for example `INNER` or `LEFT`.
      # @param as [String, Symbol, nil] Optional table alias; only valid for
      #   string/symbol table names — a ClickHouse::SQL::Table handle owns its alias.
      # @param final [Boolean] Whether to append ClickHouse `FINAL`.
      # @param on [String, ClickHouse::SQL::Part, Array] ON conditions.
      # @return [ClickHouse::SQL::Join] A validated JOIN clause.
      def initialize(table, type:, as: nil, final: false, on:)
        @table = ClickHouse::SQL.coerce_raw_expression(table)
        @type = type
        @alias_name = ClickHouse::SQL.resolve_table_alias(table, as)
        @final = final
        @on = Array(on).flatten.compact.map { |condition| ClickHouse::SQL.coerce_expression(condition) }
        raise Error, "JOIN requires at least one ON condition" if @on.empty?
      end

      # Renders the JOIN with ClickHouse typed placeholders intact.
      #
      # @return [String] SQL JOIN clause.
      def to_sql
        render(redacted: false)
      end

      # Renders the JOIN with typed placeholders replaced by bind markers.
      #
      # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
      # @return [String] Redacted SQL JOIN clause.
      def to_redacted_sql(bind_index_manager)
        render(redacted: true, bind_index_manager:)
      end

      # Returns typed placeholder values used by the JOIN.
      #
      # @return [Hash{Symbol=>Object}] Placeholder values keyed by name.
      def placeholders
        ClickHouse::SQL.collect_placeholders([@table, *@on])
      end

      # Returns ClickHouse placeholder types used by the JOIN.
      #
      # @return [Hash{Symbol=>String}] Placeholder types keyed by name.
      def placeholder_types
        ClickHouse::SQL.collect_placeholder_types([@table, *@on])
      end

      private

      def render(redacted:, bind_index_manager: ClickHouse::SQL::BindIndexManager.new)
        table_sql = ClickHouse::SQL.render_part(@table, redacted:, bind_index_manager:)
        join_sql = +"#{@type} JOIN #{table_sql}"
        join_sql << " FINAL" if @final
        join_sql << " AS #{ClickHouse::SQL.validate_alias!(@alias_name)}" if @alias_name
        join_sql << " ON "
        # Each condition is parenthesized so a condition containing a top-level
        # OR cannot change the meaning of the AND-joined ON clause.
        join_sql << @on.map { |condition| "(#{ClickHouse::SQL.render_part(condition, redacted:, bind_index_manager:)})" }.join(" AND ")
        join_sql
      end
    end
  end
end
