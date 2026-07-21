# frozen_string_literal: true

module ClickHouse
  module SQL
    # A SELECT expression with an optional validated alias.
    #
    # @!attribute expression
    #   @return [ClickHouse::SQL::Part] SQL expression to select.
    # @!attribute alias_name
    #   @return [String, Symbol, nil] Optional output alias.
    SelectItem = Struct.new(:expression, :alias_name, keyword_init: true) do
      include Part

      # Renders the SELECT expression.
      #
      # @return [String] SQL select item.
      def to_sql
        return expression.to_sql unless alias_name

        "#{expression.to_sql} AS #{ClickHouse::SQL.validate_alias!(alias_name)}"
      end

      # Renders the SELECT expression with typed placeholders redacted.
      #
      # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
      # @return [String] Redacted SQL select item.
      def to_redacted_sql(bind_index_manager)
        return expression.to_redacted_sql(bind_index_manager) unless alias_name

        "#{expression.to_redacted_sql(bind_index_manager)} AS #{ClickHouse::SQL.validate_alias!(alias_name)}"
      end

      # Returns typed placeholder values used by the SELECT expression.
      #
      # @return [Hash{Symbol=>Object}] Placeholder values keyed by name.
      def placeholders
        expression.placeholders
      end

      # Returns ClickHouse placeholder types used by the SELECT expression.
      #
      # @return [Hash{Symbol=>String}] Placeholder types keyed by name.
      def placeholder_types
        expression.placeholder_types
      end
    end
  end
end
