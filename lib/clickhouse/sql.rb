# frozen_string_literal: true

require "date"

require_relative "sql/error"
require_relative "sql/bind_index_manager"
require_relative "sql/part"
require_relative "sql/query"
require_relative "sql/placeholder"
require_relative "sql/select_item"
require_relative "sql/raw"
require_relative "sql/setting"
require_relative "sql/placeholder_type"
require_relative "sql/fragment"
require_relative "sql/table"
require_relative "sql/join"
require_relative "sql/select_query"

module ClickHouse
  # Builds composable ClickHouse SELECT queries for ClickHouse::HTTPClient.
  #
  # Keep ClickHouse SQL visible, but pass runtime values through named typed
  # placeholders (`{name:Type}`). Untyped placeholders are fragment slots for
  # trusted SQL structure such as column references or subqueries: anonymous
  # `{}` slots are filled by positional arguments in source order, and named
  # `{name}` slots by keyword arguments.
  #
  # Table handles (ClickHouse::SQL.table) build validated, qualified column
  # references so shared fragments stay unambiguous when queries join tables
  # with overlapping column names.
  #
  # @example Build and execute a typed SELECT query joining two tables
  #   CH = ClickHouse::SQL
  #
  #   requests = CH.table("requests")
  #   endpoints = CH.table("endpoints", as: "e")
  #
  #   query = CH
  #     .select(requests.columns(:id, :timestamp), endpoints[:state])
  #     .from(requests)
  #     .left_join(endpoints, final: true, on: [
  #       CH.fragment("{} = {}", endpoints[:id], requests[:endpoint_id]),
  #     ])
  #     .where("{} = {service_id:UUID}", requests[:service_id], service_id: service.id)
  #     .where("{}.{tag_key:Identifier} = {value:String}", requests[:tags], tag_key: "geo.country", value: "AU")
  #
  #   ClickHouse::HTTPClient.select(query.to_query, :analytics)
  module SQL
    UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    # Validates `{x:Identifier}` placeholder values, which ClickHouse
    # substitutes server-side with proper identifier quoting; permissive
    # enough for hyphenated tag keys.
    IDENTIFIER_REGEX = /\A[A-Za-z_][0-9A-Za-z_.-]*\z/

    # Validates identifiers that Ruby interpolates into raw SQL with no
    # quoting (table handles). Stricter than IDENTIFIER_REGEX: each
    # dot-separated segment must be a simple identifier, so `-` (a SQL
    # comment starter or subtraction) and stray dots never reach SQL text.
    QUALIFIED_IDENTIFIER_REGEX = /\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\z/
    GENERATED_BIND_PREFIX_REGEX = /\A[A-Za-z_]\w*\z/
    # Braces would terminate a generated placeholder early (or misalign the
    # parser), smuggling the remainder of the type into the SQL as raw text,
    # so a generated bind type must not contain them. Anything else stays
    # inside the placeholder and is validated downstream.
    GENERATED_BIND_TYPE_REGEX = /\A[^{}]+\z/
    SQL_ALIAS_REGEX = /\A[A-Za-z_]\w*\z/
    SETTING_NAME_REGEX = /\A[A-Za-z_]\w*\z/

    module ValueNormalization
      BLANK_STRING = /\A[[:space:]]*\z/

      def self.blank_string?(value)
        !value || BLANK_STRING.match?(value.to_s)
      end

      def self.symbolize_keys(hash)
        hash.transform_keys do |key|
          key.respond_to?(:to_sym) ? key.to_sym : key
        end
      end
    end
    private_constant :ValueNormalization

    module_function

    # Builds a SQL expression with typed placeholder values and fragment slots.
    #
    # Anonymous `{}` slots are filled in source order by positional SQL parts.
    # Named `{name}` slots and `{name:Type}` values take keyword bindings.
    #
    # @param sql [String, #to_s] SQL containing `{name:Type}` value placeholders,
    #   `{name}` fragment slots, and/or anonymous `{}` fragment slots.
    # @param args [Array<ClickHouse::SQL::Part, Hash>] Positional fills for `{}`
    #   slots in source order; a Hash argument is treated as named bindings.
    # @param keyword_bindings [Hash] Additional placeholder values keyed by name.
    # @return [ClickHouse::SQL::Fragment] A composable SQL fragment.
    def fragment(sql, *args, **keyword_bindings)
      hashes, fills = args.partition { |arg| arg.is_a?(Hash) }
      bindings = hashes.reduce({}, :merge)
      Fragment.new(sql, merge_bindings(bindings, keyword_bindings), fills:)
    end

    # Wraps trusted static SQL that has no placeholder values.
    #
    # @param sql [String, #to_s] Trusted SQL structure or expression.
    # @return [ClickHouse::SQL::Raw] A raw SQL expression.
    def raw_static(sql)
      Raw.new(sql)
    end

    # Wraps an explicitly reviewed dynamic SQL escape hatch.
    #
    # @param sql [String, #to_s] SQL that cannot be represented with placeholders.
    # @param reason [String] Durable explanation for why raw SQL is safe here.
    # @return [ClickHouse::SQL::Raw] A raw SQL expression with an audit reason.
    def unsafe_raw(sql, reason:)
      raise Error, "unsafe_raw requires a reason" if ValueNormalization.blank_string?(reason)

      Raw.new(sql, unsafe_reason: reason)
    end

    # Builds a validated table handle that qualifies column references.
    #
    # @param name [String, Symbol, #to_s] Trusted table name.
    # @param as [String, Symbol, nil] Optional table alias.
    # @return [ClickHouse::SQL::Table] A validated table handle.
    def table(name, as: nil)
      Table.new(name, as:)
    end

    # Builds a standalone JOIN clause for SelectQuery#joins.
    #
    # Useful for join specs shared between queries, so the joined table, its
    # alias, FINAL, and the ON conditions travel together.
    #
    # @param table [String, Symbol, ClickHouse::SQL::Part] Trusted table expression.
    # @param type [String] JOIN type, for example `INNER` or `LEFT`.
    # @param as [String, Symbol, nil] Optional table alias; only valid for
    #   string/symbol table names — a ClickHouse::SQL::Table handle owns its alias.
    # @param final [Boolean] Whether to append ClickHouse `FINAL`.
    # @param on [String, ClickHouse::SQL::Part, Array] ON conditions.
    # @return [ClickHouse::SQL::Join] A validated JOIN clause.
    def join(table, type: "INNER", as: nil, final: false, on:)
      Join.new(table, type:, as:, final:, on:)
    end

    # Builds a standalone LEFT JOIN clause for SelectQuery#joins.
    #
    # @param table [String, Symbol, ClickHouse::SQL::Part] Trusted table expression.
    # @param as [String, Symbol, nil] Optional table alias; only valid for
    #   string/symbol table names — a ClickHouse::SQL::Table handle owns its alias.
    # @param final [Boolean] Whether to append ClickHouse `FINAL`.
    # @param on [String, ClickHouse::SQL::Part, Array] ON conditions.
    # @return [ClickHouse::SQL::Join] A validated LEFT JOIN clause.
    def left_join(table, as: nil, final: false, on:)
      join(table, type: "LEFT", as:, final:, on:)
    end

    # Returns a trusted `*` select expression.
    #
    # @return [ClickHouse::SQL::Raw] A raw `*` expression.
    def star
      raw_static("*")
    end

    # Starts a mutable SELECT query.
    #
    # @param columns [Array<String, Symbol, ClickHouse::SQL::Part>] SELECT expressions.
    # @param aliases [Hash{Symbol,String=>String,Symbol,ClickHouse::SQL::Part}] Aliased expressions.
    # @return [ClickHouse::SQL::SelectQuery] A chainable SELECT query.
    def select(*columns, **aliases)
      SelectQuery.new.select(*columns, **aliases)
    end

    # Joins present fragments with `AND`, parenthesizing each fragment so a
    # fragment containing a top-level `OR` cannot change the clause's meaning.
    #
    # @param fragments [Array<String, Symbol, ClickHouse::SQL::Part, nil>] SQL fragments to join.
    # @return [ClickHouse::SQL::Fragment, nil] Joined fragment, or nil when no fragments are present.
    def and(fragments)
      join_fragments(fragments, " AND ", wrap: true)
    end

    # Joins present fragments with `OR`, parenthesizing each fragment so a
    # fragment containing a top-level `AND` cannot change the clause's meaning.
    #
    # @param fragments [Array<String, Symbol, ClickHouse::SQL::Part, nil>] SQL fragments to join.
    # @return [ClickHouse::SQL::Fragment, nil] Joined fragment, or nil when no fragments are present.
    def or(fragments)
      join_fragments(fragments, " OR ", wrap: true)
    end

    # Joins present fragments with `, `.
    #
    # @param fragments [Array<String, Symbol, ClickHouse::SQL::Part, nil>] SQL fragments to join.
    # @return [ClickHouse::SQL::Fragment, nil] Joined fragment, or nil when no fragments are present.
    def csv(fragments)
      join_fragments(fragments, ", ")
    end

    # Wraps a fragment in parentheses.
    #
    # @param fragment [String, Symbol, ClickHouse::SQL::Part] SQL expression to wrap.
    # @return [ClickHouse::SQL::Fragment] Parenthesized SQL fragment.
    def parens(fragment)
      Fragment.new("({})", fills: [coerce_expression(fragment)])
    end

    # Builds a comma-separated list of generated typed placeholders.
    #
    # @param prefix [String, Symbol] Safe prefix for generated placeholder names.
    # @param values [Array, Object] Values to bind; non-arrays are wrapped.
    # @param type [String] ClickHouse placeholder type for every value.
    # @param compact [Boolean] Whether to use shorter base-36 placeholder suffixes.
    # @return [ClickHouse::SQL::Fragment] Comma-separated placeholder fragment.
    def bind_list(prefix, values, type:, compact: false)
      unless prefix.to_s.match?(GENERATED_BIND_PREFIX_REGEX)
        raise Error, "Generated bind prefix must be a simple identifier: #{prefix.inspect}"
      end

      unless type.to_s.match?(GENERATED_BIND_TYPE_REGEX)
        raise Error, "Generated bind type must not be blank or contain braces: #{type.inspect}"
      end

      values = Array(values)
      raise Error, "bind_list requires at least one value" if values.empty?

      bindings = {}
      placeholders = values.each_with_index.map do |value, index|
        name = generated_bind_name(prefix, index, compact:)
        bindings[name.to_sym] = value
        "{#{name}:#{type}}"
      end

      Fragment.new(placeholders.join(", "), bindings)
    end

    # Builds a validated ClickHouse SETTINGS assignment.
    #
    # @param name [String, Symbol] ClickHouse setting name.
    # @param value [String, Integer, Float, Boolean] Inline setting value.
    # @return [ClickHouse::SQL::Setting] A rendered setting expression.
    def setting(name, value)
      Setting.new(name, value)
    end

    # Parses ClickHouse placeholder markers from SQL text.
    #
    # @param sql [String, #to_s] SQL text containing `{name}` or `{name:Type}` markers.
    # @return [Array<ClickHouse::SQL::Placeholder>] Parsed placeholders in source order.
    def parse_placeholders(sql)
      sql = sql.to_s
      placeholders = []
      index = 0

      while (open_pos = sql.index("{", index))
        close_pos = sql.index("}", open_pos + 1)
        raise Error, "Unclosed ClickHouse placeholder in SQL fragment" unless close_pos

        raw = sql[open_pos..close_pos]
        content = raw[1...-1]
        if ValueNormalization.blank_string?(content)
          # `{}` is an anonymous fragment slot, filled positionally.
          placeholders << Placeholder.new(
            raw:,
            name: nil,
            type: nil,
            begin_pos: open_pos,
            end_pos: close_pos + 1
          )
          index = close_pos + 1
          next
        end

        # A colon must be followed by a non-empty type; `{name:}` is invalid
        # rather than silently becoming an untyped fragment slot.
        match = content.match(/\A\s*([A-Za-z_]\w*)\s*(?::\s*(\S.*?)\s*)?\z/m)
        raise Error, "Invalid ClickHouse placeholder #{raw.inspect}" unless match

        placeholders << Placeholder.new(
          raw:,
          name: match[1],
          type: match[2]&.strip,
          begin_pos: open_pos,
          end_pos: close_pos + 1
        )

        index = close_pos + 1
      end

      placeholders
    end

    # Validates a simple SQL alias.
    #
    # @param alias_name [String, Symbol, #to_s] Alias to validate.
    # @return [String] The validated alias string.
    def validate_alias!(alias_name)
      alias_name = alias_name.to_s
      return alias_name if alias_name.match?(SQL_ALIAS_REGEX)

      raise Error, "SQL alias must be a simple identifier: #{alias_name.inspect}"
    end

    # Resolves a clause alias against a table expression's own alias.
    #
    # A ClickHouse::SQL::Table handle owns its alias so qualified column
    # references built from it always match the rendered FROM/JOIN clause.
    # An explicit clause alias alongside a handle — even one matching the
    # handle's alias — would create a second source of truth that can drift,
    # so it raises instead.
    #
    # @param table [Object] Table expression, possibly a ClickHouse::SQL::Table.
    # @param as [String, Symbol, nil] Explicit clause alias, if any.
    # @return [String, Symbol, nil] The alias to render, if any.
    def resolve_table_alias(table, as)
      return as unless table.is_a?(ClickHouse::SQL::Table)

      unless as.nil?
        raise Error, "A table handle owns its alias; pass the alias when creating the handle: " \
          "ClickHouse::SQL.table(#{table.name.inspect}, as: #{as.to_s.inspect})"
      end

      table.alias_name
    end

    # Validates a ClickHouse setting name.
    #
    # @param name [String, Symbol, #to_s] Setting name to validate.
    # @return [String] The validated setting name.
    def validate_setting_name!(name)
      name = name.to_s
      return name if name.match?(SETTING_NAME_REGEX)

      raise Error, "ClickHouse setting name must be a simple identifier: #{name.inspect}"
    end

    # Coerces a value into a SQL expression that may contain placeholders.
    #
    # @param value [String, Symbol, ClickHouse::SQL::Part, nil] Expression value.
    # @return [ClickHouse::SQL::Part, nil] Coerced SQL expression.
    def coerce_expression(value)
      case value
      when nil
        nil
      when ClickHouse::SQL::Part
        value
      when String
        Fragment.new(value)
      when Symbol
        Raw.new(value.to_s)
      else
        raise Error, "Expected a SQL fragment or trusted SQL string, got #{value.class}"
      end
    end

    # Coerces a value into trusted raw SQL expression context.
    #
    # @param value [String, Symbol, ClickHouse::SQL::Part, nil] Raw expression value.
    # @return [ClickHouse::SQL::Part, nil] Coerced raw SQL expression.
    def coerce_raw_expression(value)
      case value
      when nil
        nil
      when ClickHouse::SQL::Part
        value
      when String
        Raw.new(value)
      when Symbol
        Raw.new(value.to_s)
      else
        raise Error, "Expected a trusted SQL string, got #{value.class}"
      end
    end

    # Inspects a value for an error message without embedding whole
    # user-supplied values, which would otherwise travel into error trackers
    # when a caller bug raises.
    #
    # @param value [Object] Value to render into an error message.
    # @param limit [Integer] Maximum inspected length kept verbatim.
    # @return [String] Inspect output, truncated when oversized.
    def truncated_inspect(value, limit: 32)
      inspected = value.inspect
      return inspected if inspected.length <= limit

      "#{inspected[0, limit]}… (truncated #{value.class}, #{inspected.length} chars)"
    end

    # Merges placeholder values, rejecting duplicate names with different values.
    #
    # @param target [Hash{Symbol=>Object}] Placeholder values to mutate.
    # @param source [Hash{Symbol,String=>Object}] Placeholder values to merge in.
    # @return [Hash{Symbol=>Object}] The mutated target hash.
    def merge_placeholders!(target, source)
      source.each do |key, value|
        key = key.to_sym
        if target.key?(key) && target[key] != value
          raise Error, "mismatching values for the '#{key}' placeholder: " \
            "#{truncated_inspect(target[key])} vs #{truncated_inspect(value)}"
        end

        target[key] = value
      end

      target
    end

    # Merges placeholder types, rejecting duplicate names with different types.
    #
    # @param target [Hash{Symbol=>String}] Placeholder types to mutate.
    # @param source [Hash{Symbol,String=>String}] Placeholder types to merge in.
    # @return [Hash{Symbol=>String}] The mutated target hash.
    def merge_placeholder_types!(target, source)
      source.each do |key, type|
        key = key.to_sym
        if target.key?(key) && target[key] != type
          raise Error, "mismatching types for the '#{key}' placeholder: #{target[key]} vs #{type}"
        end

        target[key] = type
      end

      target
    end

    # Normalizes placeholder type spelling for comparison.
    #
    # @param type [String, #to_s] ClickHouse placeholder type.
    # @return [String] Type with whitespace removed.
    def normalize_placeholder_type(type)
      type.to_s.gsub(/\s+/, "")
    end

    # Renders a query part in normal or redacted mode.
    #
    # @param part [ClickHouse::SQL::Part] Query part to render.
    # @param redacted [Boolean] Whether to render typed placeholders as `?`-style bind markers.
    # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
    # @return [String] Rendered SQL.
    def render_part(part, redacted:, bind_index_manager:)
      if redacted
        part.to_redacted_sql(bind_index_manager)
      else
        part.to_sql
      end
    end

    # Collects placeholder values from query parts.
    #
    # @param parts [Array<#placeholders, nil>] Query parts to inspect.
    # @return [Hash{Symbol=>Object}] Merged placeholder values.
    def collect_placeholders(parts)
      parts.compact.each_with_object({}) do |part, placeholders|
        next unless part.respond_to?(:placeholders)

        merge_placeholders!(placeholders, part.placeholders)
      end
    end

    # Collects placeholder types from query parts.
    #
    # @param parts [Array<#placeholder_types, nil>] Query parts to inspect.
    # @return [Hash{Symbol=>String}] Merged placeholder type names.
    def collect_placeholder_types(parts)
      parts.compact.each_with_object({}) do |part, placeholder_types|
        next unless part.respond_to?(:placeholder_types)

        merge_placeholder_types!(placeholder_types, part.placeholder_types)
      end
    end

    # Splits a ClickHouse type argument list on top-level commas.
    #
    # @param input [String, #to_s] Argument list without the outer type name.
    # @return [Array<String>] Top-level argument strings.
    def split_top_level_arguments(input)
      input = input.to_s
      arguments = []
      start = 0
      depth = 0
      quote = nil
      escaped = false

      input.each_char.with_index do |char, index|
        if quote
          # An escaped character never closes the string; a backslash that is
          # not itself escaped escapes the character after it.
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == quote
            quote = nil
          end
          next
        end

        case char
        when "'", '"'
          quote = char
        when "("
          depth += 1
        when ")"
          depth -= 1 if depth.positive?
        when ","
          next unless depth.zero?

          arguments << input[start...index].strip
          start = index + 1
        end
      end

      arguments << input[start..].to_s.strip
      arguments
    end

    # Merges positional and keyword bindings for a fragment.
    #
    # @param bindings [Hash, nil] Explicit bindings hash.
    # @param keyword_bindings [Hash] Keyword bindings hash.
    # @return [Hash{Symbol=>Object}] Symbol-keyed merged bindings.
    def merge_bindings(bindings, keyword_bindings)
      ValueNormalization.symbolize_keys((bindings || {}).merge(keyword_bindings))
    end

    # Builds a generated placeholder name.
    #
    # @param prefix [String, Symbol, #to_s] Placeholder name prefix.
    # @param index [Integer] Zero-based generated placeholder index.
    # @param compact [Boolean] Whether to use base-36 suffixes.
    # @return [String] Generated placeholder name.
    def generated_bind_name(prefix, index, compact:)
      return "#{prefix}_#{index}" unless compact

      "#{prefix}#{index.to_s(36)}"
    end

    # Returns whether a value is a renderable SQL builder part.
    #
    # @param value [Object] Value to check.
    # @return [Boolean] True when value implements ClickHouse::SQL's internal part protocol.
    def part?(value)
      value.is_a?(ClickHouse::SQL::Part)
    end

    # Joins fragments with a separator while preserving nested placeholders.
    #
    # @param fragments [Array<String, Symbol, ClickHouse::SQL::Part, nil>] Fragments to join.
    # @param separator [String] SQL separator to place between fragments.
    # @param wrap [Boolean] Whether to parenthesize each fragment, for boolean separators.
    # @return [ClickHouse::SQL::Fragment, nil] Joined fragment, or nil when empty.
    def join_fragments(fragments, separator, wrap: false)
      fills = Array(fragments).flatten.compact.map { |fragment| coerce_expression(fragment) }
      return nil if fills.empty?

      slots = fills.map { wrap ? "({})" : "{}" }
      Fragment.new(slots.join(separator), fills:)
    end
  end
end
