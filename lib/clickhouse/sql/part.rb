# frozen_string_literal: true

module ClickHouse
  module SQL
    # Internal protocol for renderable ClickHouse::SQL builder parts.
    module Part
      # Renders this part with typed placeholders intact.
      #
      # @return [String] SQL text.
      def to_sql
        raise NotImplementedError
      end

      # Renders this part with typed placeholders replaced by bind markers.
      #
      # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
      # @return [String] Redacted SQL text.
      def to_redacted_sql(bind_index_manager = ClickHouse::SQL::BindIndexManager.new)
        raise NotImplementedError
      end

      # Returns typed placeholder values used by this part.
      #
      # @return [Hash{Symbol=>Object}] Placeholder values keyed by name.
      def placeholders
        {}
      end

      # Returns ClickHouse placeholder types used by this part.
      #
      # @return [Hash{Symbol=>String}] Placeholder types keyed by name.
      def placeholder_types
        {}
      end
    end
  end
end
