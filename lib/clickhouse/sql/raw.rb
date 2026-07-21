# frozen_string_literal: true

module ClickHouse
  module SQL
    class Raw
      include Part

      # @return [String, nil] Reason this raw SQL is intentionally unsafe, if any.
      attr_reader :unsafe_reason

      # Builds a trusted raw SQL expression.
      #
      # @param sql [String, #to_s] Raw SQL text.
      # @param unsafe_reason [String, nil] Reason for using unsafe raw SQL.
      # @return [ClickHouse::SQL::Raw] A raw SQL expression.
      def initialize(sql, unsafe_reason: nil)
        raise Error, "Empty SQL string given" if ValueNormalization.blank_string?(sql)

        @sql = sql.to_s
        @unsafe_reason = unsafe_reason
      end

      # Renders the raw SQL text.
      #
      # @return [String] Raw SQL text.
      def to_sql
        @sql
      end

      # Renders the raw SQL text for redacted logs.
      #
      # @param _bind_index_manager [ClickHouse::SQL::BindIndexManager] Unused redacted bind index state.
      # @return [String] Raw SQL text.
      def to_redacted_sql(_bind_index_manager = ClickHouse::SQL::BindIndexManager.new)
        @sql
      end

      # Returns no placeholders because raw SQL cannot bind values.
      #
      # @return [Hash] Empty placeholder values.
      def placeholders
        {}
      end

      # Returns no placeholder types because raw SQL cannot bind values.
      #
      # @return [Hash] Empty placeholder types.
      def placeholder_types
        {}
      end
    end
  end
end
