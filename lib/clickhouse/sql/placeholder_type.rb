# frozen_string_literal: true

module ClickHouse
  module SQL
    class PlaceholderType
      # @return [String] Raw ClickHouse placeholder type text.
      attr_reader :raw

      # @return [String] Whitespace-normalized ClickHouse placeholder type text.
      attr_reader :normalized

      # Parses and normalizes a ClickHouse placeholder type.
      #
      # @param raw [String, #to_s] ClickHouse type text from a placeholder.
      # @return [ClickHouse::SQL::PlaceholderType] Parsed placeholder type.
      def initialize(raw)
        @raw = raw.to_s.strip
        @normalized = ClickHouse::SQL.normalize_placeholder_type(@raw)
      end

      # Validates and normalizes a Ruby value for this ClickHouse type.
      #
      # @param value [Object] Ruby value to validate for the placeholder type.
      # @return [Object] Value normalized for ClickHouse parameter serialization.
      def validate_and_normalize(value)
        base, arguments = parse_base_and_arguments(raw)

        if value.nil?
          return nil if nullable?

          raise Error, "#{raw} placeholder does not accept nil"
        end

        case base.downcase
        when "array"
          validate_array(value, arguments)
        when "nullable", "lowcardinality"
          validate_wrapped(value, arguments)
        when "uuid"
          validate_uuid(value)
        when "identifier"
          validate_identifier(value)
        when "string", "fixedstring"
          validate_string(value)
        when "date"
          validate_date(value)
        when "datetime"
          validate_datetime(value, timezone: timezone_argument(arguments.first))
        when "datetime64"
          validate_datetime64(value, arguments)
        when "integer"
          validate_integer(value)
        when /\Auint(\d+)\z/
          validate_sized_integer(value, bits: Regexp.last_match(1).to_i, unsigned: true)
        when /\Aint(\d+)\z/
          validate_sized_integer(value, bits: Regexp.last_match(1).to_i, unsigned: false)
        when "float32", "float64"
          validate_numeric(value)
        else
          value
        end
      end

      # Whether this type accepts nil, recursing through LowCardinality
      # wrappers since ClickHouse only permits the LowCardinality(Nullable(T))
      # nesting order.
      #
      # @return [Boolean] True if nil is a valid value for this type.
      def nullable?
        base, arguments = parse_base_and_arguments(raw)
        return true if base.casecmp?("Nullable")
        return self.class.new(arguments.first).nullable? if base.casecmp?("LowCardinality") && !arguments.first.to_s.empty?

        false
      end

      private

      def parse_base_and_arguments(type)
        match = type.match(/\A\s*([A-Za-z][A-Za-z0-9]*)\s*(?:\((.*)\))?\s*\z/m)
        raise Error, "Invalid ClickHouse placeholder type: #{type.inspect}" unless match

        [match[1], ClickHouse::SQL.split_top_level_arguments(match[2].to_s)]
      end

      def validate_array(value, arguments)
        raise Error, "Array placeholder requires an Array, got #{value.class}" unless value.is_a?(Array)

        inner_type = arguments.first
        raise Error, "Array placeholder requires an inner type" if ValueNormalization.blank_string?(inner_type)

        inner = self.class.new(inner_type)
        value.map { |item| inner.validate_and_normalize(item) }
      end

      def validate_wrapped(value, arguments)
        inner_type = arguments.first
        raise Error, "#{raw} placeholder requires an inner type" if ValueNormalization.blank_string?(inner_type)

        self.class.new(inner_type).validate_and_normalize(value)
      end

      def validate_uuid(value)
        string = value.to_s
        unless string.match?(UUID_REGEX)
          raise Error, "UUID placeholder requires a UUID-shaped value, got #{ClickHouse::SQL.truncated_inspect(value)}"
        end

        value
      end

      def validate_identifier(value)
        string = value.to_s
        unless string.match?(IDENTIFIER_REGEX) && !string.include?("..")
          raise Error, "Identifier placeholder requires a safe identifier, got #{ClickHouse::SQL.truncated_inspect(value)}"
        end

        string
      end

      def validate_string(value)
        raise Error, "String placeholder requires a String, got #{value.class}" unless value.is_a?(String)

        value
      end

      # DateTime is a subclass of Date but serializes with a time component,
      # which is not a valid ClickHouse Date literal, so it is rejected.
      def validate_date(value)
        return value if value.is_a?(Date) && !value.is_a?(DateTime)
        return value if value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        raise Error, "Date placeholder requires a Date or YYYY-MM-DD string, got #{ClickHouse::SQL.truncated_inspect(value)}"
      end

      def validate_datetime(value, timezone: nil)
        if time_like?(value)
          reject_non_utc_timezone!(timezone)
          return value.to_time.getutc
        end
        return value if value.is_a?(String)
        return value if value.is_a?(Numeric)

        raise Error, "DateTime placeholder requires a Time, DateTime, String, or Numeric, got #{ClickHouse::SQL.truncated_inspect(value)}"
      end

      def validate_datetime64(value, arguments)
        value = validate_datetime(value, timezone: timezone_argument(arguments[1]))
        return value unless value.is_a?(Time)

        precision = Integer(arguments.first, exception: false)
        return value unless precision

        format_time(value, precision)
      end

      def time_like?(value)
        value.is_a?(Time) ||
          value.is_a?(DateTime)
      end

      def timezone_argument(argument)
        timezone = argument.to_s.delete("'\"")
        timezone unless ValueNormalization.blank_string?(timezone)
      end

      # ClickHouse interprets rendered DateTime strings in the timezone the
      # placeholder type declares, so a Ruby time value can only be formatted
      # safely for UTC. Callers targeting other declared timezones must format
      # the value themselves and pass a String.
      def reject_non_utc_timezone!(timezone)
        return if timezone.nil? || timezone == "UTC"

        raise Error, "#{raw} placeholder declares a non-UTC timezone; pass a pre-formatted String instead of a time value"
      end

      def validate_integer(value)
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(String) && value.match?(/\A[+-]?\d+\z/)

        raise Error, "Integer placeholder requires an Integer or integer string, got #{value.class}"
      end

      def validate_sized_integer(value, bits:, unsigned:)
        integer = validate_integer(value)
        validate_integer_range(integer, bits:, unsigned:)
        integer
      end

      def validate_integer_range(value, bits:, unsigned:)
        min, max = if unsigned
                     [0, (2**bits) - 1]
                   else
                     [-(2**(bits - 1)), (2**(bits - 1)) - 1]
                   end
        return if value.between?(min, max)

        raise Error, "#{raw} placeholder value #{value.inspect} is outside #{min}..#{max}"
      end

      def validate_numeric(value)
        raise Error, "Float placeholder requires a Numeric, got #{value.class}" unless value.is_a?(Numeric)
        raise Error, "#{raw} placeholder value must be finite, got #{value.inspect}" unless value.finite?

        value
      end

      def format_time(time, precision)
        base = time.strftime("%Y-%m-%d %H:%M:%S")
        return base if precision <= 0

        fraction = time.nsec.to_s.rjust(9, "0")
        fraction = fraction.ljust(precision, "0") if precision > 9

        "#{base}.#{fraction[0, precision]}"
      end
    end
  end
end
