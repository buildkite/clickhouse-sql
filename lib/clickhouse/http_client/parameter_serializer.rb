# frozen_string_literal: true

module ClickHouse
  module HTTPClient
    # Serializes Ruby placeholder values into the text format ClickHouse
    # expects for query parameters, for binding values into SQL.
    #
    # ClickHouse parses a top-level parameter value in its escaped text
    # format, where an unquoted `\N` denotes NULL, while values nested inside
    # Array/Map literals are parsed as SQL-like literals, where NULL is
    # spelled `NULL` and strings must be quoted.
    #
    # - https://clickhouse.com/docs/sql-reference/syntax#literals
    # - https://clickhouse.com/docs/sql-reference/syntax#defining-and-using-query-parameters
    module ParameterSerializer
      # Serializes a value for the top/outer/root layer, where e.g. strings
      # don't need to be surrounded by quotes (whereas e.g. strings in an
      # Array do need quotes).
      #
      # @param input [Object] Placeholder value to serialize.
      # @return [String] ClickHouse parameter text.
      def self.serialize(input)
        case input

        when NilClass
          "\\N"

        when String
          escape_top_level_string(input)

        when Symbol
          escape_top_level_string(input.to_s)

        when Array
          elements = input.map { serialize_nested(_1) }
          "[#{elements.join(",")}]"

        when Hash
          elements = input.map { |k, v| serialize_nested(k) + ":" + serialize_nested(v) }
          "{#{elements.join(",")}}"

        when DateTime
          # DateTime is a Date subclass, so it must be matched first and
          # converted to a Time (preserving its offset) to render as UTC
          # wall-clock text like Time below, not as a date-only string.
          serialize(input.to_time)

        when Date
          input.to_s # Ruby and ClickHouse agree on YYYY-MM-DD

        when Time
          # ClickHouse interprets the rendered text in the placeholder's (or
          # server's) timezone, so only UTC wall-clock text is safe to send.
          # Sub-second precision is dropped; when precision matters, callers
          # pre-format the value as a String (as ClickHouse::SQL does for
          # DateTime64 placeholders).
          input.getutc.strftime("%Y-%m-%d %H:%M:%S")

        else
          input.to_s
        end
      end

      # Serializes a value nested within a container e.g. an Array or
      # Hash/Map, where strings are surrounded by quotes and NULL is spelled
      # out.
      #
      # @param input [Object] Nested placeholder value to serialize.
      # @return [String] ClickHouse literal text.
      def self.serialize_nested(input)
        case input

        when NilClass
          "NULL"

        when Symbol
          serialize_nested(input.to_s)

        when String
          quote_and_escape_string(input)

        when Date, Time
          quote_and_escape_string(serialize(input))

        else
          serialize(input)
        end
      end

      # ClickHouse parses each top-level parameter value with the type's
      # escaped-text deserialization: backslash sequences (\t, \n, \N, \xNN,
      # ...) are decoded, and a literal TAB or LF byte terminates the value,
      # failing the query. Escaping the backslash and terminator bytes makes
      # String values round-trip byte-for-byte. Values serialized from other
      # Ruby types cannot contain these bytes.
      ESCAPED_TEXT_REPLACEMENTS = {
        "\\" => "\\\\",
        "\t" => "\\t",
        "\n" => "\\n",
        "\r" => "\\r",
      }.freeze

      # Escapes a top-level String value for ClickHouse's escaped text format.
      #
      # @param str [String] String value to escape.
      # @return [String] Escaped parameter text.
      def self.escape_top_level_string(str)
        str.gsub(/[\\\t\n\r]/, ESCAPED_TEXT_REPLACEMENTS)
      end

      # Escapes each single-quote and backslash by prefixing it with a
      # backslash, and wraps the result in single quotes.
      #
      # @param str [String] String value to quote.
      # @return [String] Quoted and escaped string literal.
      def self.quote_and_escape_string(str)
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
