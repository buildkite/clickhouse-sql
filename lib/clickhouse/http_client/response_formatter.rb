# frozen_string_literal: true

module ClickHouse
  module HTTPClient
    # Typecasts values from ClickHouse's JSON response according to the
    # declared column metadata.
    module ResponseFormatter
      TYPE_CASTERS = [
        [/\AU?Int\d+\z/, ->(value) { Integer(value) }],
        [/\AFloat(?:32|64)\z/, ->(value) { Float(value) }],
        [/\ADate(?:32)?\z/, ->(value) { Date.parse(value) }],
        # ClickHouse renders zone-less DateTime/DateTime64 values in the
        # *server's* default timezone, so parsing them as UTC assumes every
        # ClickHouse server in the fleet runs UTC. Explicit non-UTC zones
        # deliberately don't match and pass through as strings.
        [/\ADateTime(?:64)?(?:\(\d+\)|\(\d+,\s*'UTC'\)|\('UTC'\))?\z/, ->(value) { Time.parse("#{value} UTC") }],
        [/\AIntervalSecond\z/, ->(value) { Integer(value) }],
        [/\AIntervalMillisecond\z/, ->(value) { Integer(value) / 1000.0 }],
      ].freeze
      private_constant :TYPE_CASTERS

      IDENTITY = ->(value) { value }
      private_constant :IDENTITY

      # Type wrappers that don't change the text encoding of the inner value.
      WRAPPER_TYPE = /\A(?:Nullable|LowCardinality)\((.*)\)\z/
      private_constant :WRAPPER_TYPE

      AGGREGATE_WRAPPER_TYPE = /\ASimpleAggregateFunction\(\s*\w+\s*,\s*(.*)\)\z/
      private_constant :AGGREGATE_WRAPPER_TYPE

      ARRAY_TYPE = /\AArray\((.*)\)\z/
      private_constant :ARRAY_TYPE

      def self.format_rows(parsed)
        casters = parsed["meta"].to_h do |column|
          [column["name"], caster_for(column["type"])]
        end

        parsed["data"].map do |row|
          row.to_h { |column, value| [column, casters.fetch(column, IDENTITY).call(value)] }
        end
      end

      def self.caster_for(type)
        unwrapped = unwrap_type(type)

        # Array elements need the same casting as scalars: JSON output quotes
        # 64-bit integers and datetimes inside arrays too, so Array(UInt64)
        # arrives as an array of strings.
        if (array = ARRAY_TYPE.match(unwrapped))
          element_caster = caster_for(array[1].strip)
          return IDENTITY if element_caster.equal?(IDENTITY)

          return ->(value) { value.nil? ? nil : value.map { |element| element_caster.call(element) } }
        end

        _, cast = TYPE_CASTERS.find { |regex, _| regex.match?(unwrapped) }
        return IDENTITY unless cast

        ->(value) { value.nil? ? nil : cast.call(value) }
      end
      private_class_method :caster_for

      def self.unwrap_type(type)
        type = type.to_s

        while (match = WRAPPER_TYPE.match(type) || AGGREGATE_WRAPPER_TYPE.match(type))
          type = match[1]
        end

        type
      end
      private_class_method :unwrap_type
    end
    private_constant :ResponseFormatter
  end
end
