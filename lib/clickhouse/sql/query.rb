# frozen_string_literal: true

module ClickHouse
  module SQL
    class Query
      include Part

      REDACTED_BIND_TOKEN = "\0clickhouse_sql_bind\0"
      private_constant :REDACTED_BIND_TOKEN

      class RedactedBindIndexManager
        # Returns an internal marker used when compiling redacted SQL templates.
        #
        # @return [String] Redacted bind marker token.
        def next_bind_str
          REDACTED_BIND_TOKEN
        end
      end
      private_constant :RedactedBindIndexManager

      # Builds a bind index manager for compiled redacted SQL templates.
      #
      # @return [#next_bind_str] Bind index manager that emits internal bind tokens.
      def self.redacted_bind_index_manager
        RedactedBindIndexManager.new
      end

      # Builds an immutable query object satisfying the client query protocol
      # (#to_sql and #placeholders) accepted by ClickHouse::HTTPClient.
      #
      # @param sql [String, #to_s] Fully rendered SQL containing typed ClickHouse placeholders.
      # @param redacted_sql [String, #to_s] Redacted SQL template containing internal bind tokens.
      # @param placeholders [Hash{Symbol,String=>Object}] Placeholder values keyed by name.
      # @param placeholder_types [Hash{Symbol,String=>String}] Placeholder types keyed by name.
      # @return [ClickHouse::SQL::Query] Immutable client query object.
      def initialize(sql:, redacted_sql:, placeholders:, placeholder_types:)
        raise Error, "Empty SQL query given" if ValueNormalization.blank_string?(sql)
        raise Error, "Empty redacted SQL query given" if ValueNormalization.blank_string?(redacted_sql)

        @sql = sql.to_s.dup.freeze
        @redacted_sql = redacted_sql.to_s.dup.freeze
        @placeholders = immutable_symbolized_hash(placeholders)
        @placeholder_types = immutable_symbolized_hash(placeholder_types)

        validate_nil_placeholders!
        freeze
      end

      # Renders the final SQL with ClickHouse typed placeholders intact.
      #
      # @return [String] SQL query text.
      def to_sql
        @sql
      end

      # Renders the final SQL with typed placeholders replaced by bind markers.
      #
      # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
      # @return [String] Redacted SQL query text.
      def to_redacted_sql(bind_index_manager = ClickHouse::SQL::BindIndexManager.new)
        parts = @redacted_sql.split(REDACTED_BIND_TOKEN, -1)
        return @redacted_sql if parts.length == 1

        parts.each_with_index.with_object(+"") do |(part, index), rendered|
          rendered << part
          rendered << bind_index_manager.next_bind_str unless index == parts.length - 1
        end
      end

      # Returns typed placeholder values used by this query.
      #
      # @return [Hash{Symbol=>Object}] Placeholder values keyed by name.
      attr_reader :placeholders

      # Returns ClickHouse placeholder types used by this query.
      #
      # @return [Hash{Symbol=>String}] Placeholder types keyed by name.
      attr_reader :placeholder_types

      private

      def immutable_symbolized_hash(hash)
        ValueNormalization.symbolize_keys(hash)
          .transform_values { |value| immutable_copy(value) }
          .freeze
      end

      def immutable_copy(value)
        case value
        when Array
          value.map { |item| immutable_copy(item) }.freeze
        when Hash
          value.to_h { |key, item| [immutable_copy(key), immutable_copy(item)] }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end

      # The client sends nil placeholder values as NULL, which only a
      # Nullable placeholder type can represent. For most non-Nullable types
      # ClickHouse rejects NULL loudly, but a plain String placeholder
      # silently parses it as an empty string — so nils are validated against
      # the declared placeholder types here, where both are known.
      def validate_nil_placeholders!
        @placeholders.each do |name, value|
          type = @placeholder_types[name].to_s

          if value.nil?
            next if !ValueNormalization.blank_string?(type) && PlaceholderType.new(type).nullable?

            raise Error, "nil bound to non-Nullable placeholder {#{name}:#{type}}; declare the type as Nullable(...) to bind NULL"
          elsif contains_nil?(value)
            next if type.include?("Nullable(")

            raise Error, "nil element bound to non-Nullable placeholder {#{name}:#{type}}; declare the element type as Nullable(...) to bind NULLs"
          end
        end
      end

      def contains_nil?(value)
        case value
        when Array
          value.any? { |item| item.nil? || contains_nil?(item) }
        when Hash
          value.any? { |key, item| key.nil? || item.nil? || contains_nil?(key) || contains_nil?(item) }
        else
          false
        end
      end
    end
  end
end
