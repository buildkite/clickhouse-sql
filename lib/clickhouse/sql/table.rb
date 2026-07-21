# frozen_string_literal: true

module ClickHouse
  module SQL
    # A validated table reference that qualifies column references.
    #
    # A table handle renders as its table name in FROM/JOIN position, and
    # builds qualified column references via `#[]` so shared fragments stay
    # unambiguous when a query joins tables with overlapping column names.
    #
    # @example Qualified columns from a table handle
    #   events = CH.table("events")
    #   accounts = CH.table("accounts", as: "a")
    #
    #   CH.select(events[:account_id])
    #     .from(events)
    #     .left_join(accounts, final: true, on: [
    #       CH.fragment("{} = {}", accounts[:id], events[:account_id]),
    #     ])
    #     .where("{} >= {from:DateTime64(6)}", events[:timestamp], from: from_time)
    class Table
      include Part

      # @return [String] Validated table name.
      attr_reader :name

      # @return [String, nil] Validated table alias, if any.
      attr_reader :alias_name

      # Builds a validated table handle.
      #
      # @param name [String, Symbol, #to_s] Trusted table name.
      # @param as [String, Symbol, nil] Optional table alias.
      # @return [ClickHouse::SQL::Table] A validated table handle.
      def initialize(name, as: nil)
        @name = validate_identifier!(name)
        @alias_name = as.nil? ? nil : ClickHouse::SQL.validate_alias!(as)
      end

      # Builds a qualified column reference using the alias when present.
      #
      # @param column [String, Symbol, #to_s] Trusted column name or nested path.
      # @return [ClickHouse::SQL::Raw] Qualified column expression.
      def [](column)
        Raw.new("#{qualifier}.#{validate_identifier!(column)}")
      end

      # Builds qualified column references for many columns at once.
      #
      # Accepts names as arguments or arrays (`t.columns(%i[id timestamp])`).
      # SelectQuery#select flattens arrays, so the result can be passed with or
      # without a splat.
      #
      # @param names [Array<String, Symbol, Array>] Trusted column names or nested paths.
      # @return [Array<ClickHouse::SQL::Raw>] Qualified column expressions.
      def columns(*names)
        names.flatten.map { |name| self[name] }
      end

      # Returns the name this table's columns are qualified with.
      #
      # @return [String] The table alias when present, otherwise the table name.
      def qualifier
        @alias_name || @name
      end

      # Renders the table name for FROM/JOIN position.
      #
      # @return [String] The table name.
      def to_sql
        @name
      end

      # Renders the table name for redacted logs.
      #
      # @param _bind_index_manager [ClickHouse::SQL::BindIndexManager] Unused redacted bind index state.
      # @return [String] The table name.
      def to_redacted_sql(_bind_index_manager = ClickHouse::SQL::BindIndexManager.new)
        @name
      end

      private

      # Table handles interpolate identifiers into raw SQL Ruby-side with no
      # quoting, unlike `{x:Identifier}` placeholders which ClickHouse
      # substitutes server-side with proper quoting. This regex is the only
      # defense, so it is stricter than the Identifier placeholder validation:
      # each dot-separated segment must be a simple identifier.
      def validate_identifier!(value)
        value = value.to_s
        return value if value.match?(QUALIFIED_IDENTIFIER_REGEX)

        raise Error, "Table identifier must be a safe identifier: #{ClickHouse::SQL.truncated_inspect(value)}"
      end
    end
  end
end
