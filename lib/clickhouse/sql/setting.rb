# frozen_string_literal: true

module ClickHouse
  module SQL
    class Setting
      include Part

      # Builds a validated ClickHouse SETTINGS assignment.
      #
      # @param name [String, Symbol] ClickHouse setting name.
      # @param value [String, Integer, Float, Boolean] Inline setting value.
      # @return [ClickHouse::SQL::Setting] A setting expression.
      def initialize(name, value)
        @name = ClickHouse::SQL.validate_setting_name!(name)
        @value = validate_value(value)
      end

      # Renders the setting assignment with its literal value.
      #
      # @return [String] SQL setting assignment.
      def to_sql
        "#{@name} = #{serialized_value}"
      end

      # Renders the setting assignment with its value redacted.
      #
      # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
      # @return [String] Redacted SQL setting assignment.
      def to_redacted_sql(bind_index_manager = ClickHouse::SQL::BindIndexManager.new)
        "#{@name} = #{bind_index_manager.next_bind_str}"
      end

      # Returns no placeholders because settings are rendered as literals.
      #
      # @return [Hash] Empty placeholder values.
      def placeholders
        {}
      end

      # Returns no placeholder types because settings are rendered as literals.
      #
      # @return [Hash] Empty placeholder types.
      def placeholder_types
        {}
      end

      private

      def validate_value(value)
        case value
        when String, Integer, TrueClass, FalseClass
          value
        when Float
          return value if value.finite?

          raise Error, "ClickHouse setting value must be finite, got #{value.inspect}"
        else
          raise Error, "ClickHouse setting value must be a String, Integer, Float, or boolean, got #{value.class}"
        end
      end

      def serialized_value
        case @value
        when String
          quote_and_escape_string(@value)
        when TrueClass
          "1"
        when FalseClass
          "0"
        else
          @value.to_s
        end
      end

      # Renders a ClickHouse single-quoted string literal, escaping each
      # single-quote and backslash by prefixing it with a backslash.
      # https://clickhouse.com/docs/sql-reference/syntax#string
      def quote_and_escape_string(str)
        # Note the double-escaping in the replacement string:
        # - Ruby strings consume one backslash
        #   - ruby syntax "\\" => ruby string "\"
        # - Regexp replacement consumes one backslash
        #   - ruby literal syntax \\\\ => ruby string \\ => regexp replacement \
        #   - ruby literal syntax \\0  => ruby string \0 => regexp replacement match #0
        "'#{str.gsub(/['\\]/, "\\\\\\0")}'"
      end
    end
  end
end
