# frozen_string_literal: true

module ClickHouse
  module SQL
    class SelectQuery
      include Part

      # Builds an empty mutable SELECT query.
      #
      # @return [ClickHouse::SQL::SelectQuery] Empty SELECT query builder.
      def initialize
        @selects = []
        @distinct = false
        @with = []
        @joins = []
        @wheres = []
        @havings = []
        @group_bys = []
        @order_bys = []
        @settings = []
      end

      # Renders `SELECT DISTINCT` instead of `SELECT`.
      #
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def distinct
        @distinct = true
        self
      end

      # Appends SELECT expressions.
      #
      # @param columns [Array<String, Symbol, ClickHouse::SQL::Part, nil>] SELECT expressions.
      # @param aliases [Hash{Symbol,String=>String,Symbol,ClickHouse::SQL::Part}] Aliased expressions.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def select(*columns, **aliases)
        columns.flatten.compact.each do |column|
          @selects << SelectItem.new(expression: ClickHouse::SQL.coerce_raw_expression(column))
        end

        aliases.each do |alias_name, expression|
          @selects << SelectItem.new(expression: ClickHouse::SQL.coerce_raw_expression(expression), alias_name:)
        end

        self
      end

      # Appends a WITH/CTE fragment, or an array of WITH/CTE fragments.
      #
      # @param fragment [String, Symbol, ClickHouse::SQL::Part, Array, nil] WITH fragment(s).
      # @param fills [Array<ClickHouse::SQL::Part>] Positional fills for anonymous `{}` slots.
      # @param bindings [Hash] Placeholder bindings for the fragment.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def with(fragment = nil, *fills, **bindings)
        append_clause(@with, fragment, fills, bindings)
      end

      # Appends a CTE named by a table handle.
      #
      # @param handle [ClickHouse::SQL::Table] Handle for the CTE relation.
      # @param query [String, Symbol, ClickHouse::SQL::Part] CTE query expression.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def with_cte(handle, query)
        unless handle.is_a?(ClickHouse::SQL::Table)
          raise Error, "CTE handle must be a table handle, got #{handle.class}"
        end

        name = ClickHouse::SQL.validate_alias!(handle.name)
        @with << ClickHouse::SQL.fragment(
          "{} AS ({})",
          ClickHouse::SQL.raw_static(name),
          ClickHouse::SQL.coerce_expression(query)
        )
        self
      end

      # Sets the FROM table expression.
      #
      # A ClickHouse::SQL::Table handle owns its alias so column references
      # built from the handle always match the rendered clause; passing `as:`
      # alongside a handle raises.
      #
      # @param table [String, Symbol, ClickHouse::SQL::Part] Trusted table expression.
      # @param as [String, Symbol, nil] Optional table alias; only valid for
      #   string/symbol table names — a ClickHouse::SQL::Table handle owns its alias.
      # @param final [Boolean] Whether to append ClickHouse `FINAL`.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def from(table, as: nil, final: false)
        @from = ClickHouse::SQL.coerce_raw_expression(table)
        @from_alias = ClickHouse::SQL.resolve_table_alias(table, as)
        @from_final = final
        self
      end

      # Sets the FROM clause to a nested query.
      #
      # @param query [String, Symbol, ClickHouse::SQL::Part] Subquery expression.
      # @param as [String, Symbol, ClickHouse::SQL::Table] Required table alias.
      #   A table handle contributes its qualifier so references built from
      #   the handle match the rendered alias.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def from_subquery(query, as:)
        @from = ClickHouse::SQL.fragment("({query})", query: ClickHouse::SQL.coerce_expression(query))
        @from_alias = as.is_a?(ClickHouse::SQL::Table) ? as.qualifier : as
        @from_final = false
        self
      end

      # Appends a JOIN clause.
      #
      # @param table [String, Symbol, ClickHouse::SQL::Part] Trusted table expression.
      # @param type [String] JOIN type, for example `INNER` or `LEFT`.
      # @param as [String, Symbol, nil] Optional table alias; only valid for
      #   string/symbol table names — a ClickHouse::SQL::Table handle owns its alias.
      # @param final [Boolean] Whether to append ClickHouse `FINAL`.
      # @param on [String, ClickHouse::SQL::Part, Array] ON conditions.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def join(table, type: "INNER", as: nil, final: false, on:)
        @joins << Join.new(table, type:, as:, final:, on:)
        self
      end

      # Appends a LEFT JOIN clause.
      #
      # @param table [String, Symbol, ClickHouse::SQL::Part] Trusted table expression.
      # @param as [String, Symbol, nil] Optional table alias; only valid for
      #   string/symbol table names — a ClickHouse::SQL::Table handle owns its alias.
      # @param final [Boolean] Whether to append ClickHouse `FINAL`.
      # @param on [String, ClickHouse::SQL::Part, Array] ON conditions.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def left_join(table, as: nil, final: false, on:)
        join(table, type: "LEFT", as:, final:, on:)
      end

      # Appends an INNER JOIN clause.
      #
      # @param table [String, Symbol, ClickHouse::SQL::Part] Trusted table expression.
      # @param as [String, Symbol, nil] Optional table alias; only valid for
      #   string/symbol table names — a ClickHouse::SQL::Table handle owns its alias.
      # @param final [Boolean] Whether to append ClickHouse `FINAL`.
      # @param on [String, ClickHouse::SQL::Part, Array] ON conditions.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def inner_join(table, as: nil, final: false, on:)
        join(table, type: "INNER", as:, final:, on:)
      end

      # Appends pre-rendered JOIN fragments.
      #
      # @param joins [Array<String, Symbol, ClickHouse::SQL::Part, nil>] JOIN fragments.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def joins(*joins)
        joins.flatten.compact.each do |join|
          @joins << ClickHouse::SQL.coerce_expression(join)
        end

        self
      end

      # Appends a WHERE condition, or an array of WHERE conditions, later
      # rendered with `AND`.
      #
      # @param condition [String, Symbol, ClickHouse::SQL::Part, Array, nil] WHERE condition(s).
      # @param fills [Array<ClickHouse::SQL::Part>] Positional fills for anonymous `{}` slots.
      # @param bindings [Hash] Placeholder bindings for the condition.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def where(condition = nil, *fills, **bindings)
        append_clause(@wheres, condition, fills, bindings)
      end

      # Appends a HAVING condition, or an array of HAVING conditions, later
      # rendered with `AND`.
      #
      # @param condition [String, Symbol, ClickHouse::SQL::Part, Array, nil] HAVING condition(s).
      # @param fills [Array<ClickHouse::SQL::Part>] Positional fills for anonymous `{}` slots.
      # @param bindings [Hash] Placeholder bindings for the condition.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def having(condition = nil, *fills, **bindings)
        append_clause(@havings, condition, fills, bindings)
      end

      # Appends GROUP BY expressions.
      #
      # @param expressions [Array<String, Symbol, ClickHouse::SQL::Part, nil>] GROUP BY expressions.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def group_by(*expressions)
        append_raw_expressions(@group_bys, expressions)
      end

      # Appends ORDER BY expressions.
      #
      # @param expressions [Array<String, Symbol, ClickHouse::SQL::Part, nil>] ORDER BY expressions.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def order_by(*expressions)
        append_raw_expressions(@order_bys, expressions)
      end

      # Sets the LIMIT expression.
      #
      # @param expression [String, Symbol, ClickHouse::SQL::Part, nil] LIMIT expression.
      # @param bindings [Hash] Placeholder bindings for the LIMIT expression.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def limit(expression = nil, **bindings)
        @limit = one_fragment(expression, bindings)
        self
      end

      # Sets the OFFSET expression.
      #
      # @param expression [String, Symbol, ClickHouse::SQL::Part, nil] OFFSET expression.
      # @param bindings [Hash] Placeholder bindings for the OFFSET expression.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def offset(expression = nil, **bindings)
        @offset = one_fragment(expression, bindings)
        self
      end

      # Appends static SETTINGS fragments.
      #
      # @param settings [Array<String, Symbol, ClickHouse::SQL::Part, nil>] SETTINGS fragments.
      # @param bindings [Hash] Unsupported; ClickHouse does not parameterize SETTINGS.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def settings(*settings, **bindings)
        if bindings.any?
          raise Error, "ClickHouse SETTINGS do not support query parameters; use setting(name, value) for dynamic setting values"
        end

        settings.flatten.compact.each { |setting| @settings << ClickHouse::SQL.coerce_expression(setting) }
        validate_settings!
        self
      end

      # Appends one validated SETTINGS assignment.
      #
      # @param name [String, Symbol] ClickHouse setting name.
      # @param value [String, Integer, Float, Boolean] Inline setting value.
      # @return [ClickHouse::SQL::SelectQuery] This query.
      def setting(name, value)
        @settings << Setting.new(name, value)
        self
      end

      # Renders the SELECT query with ClickHouse typed placeholders intact.
      #
      # @return [String] SQL query text.
      def to_sql
        render(redacted: false)
      end

      # Renders the SELECT query with typed placeholders replaced by bind markers.
      #
      # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
      # @return [String] Redacted SQL query text.
      def to_redacted_sql(bind_index_manager = ClickHouse::SQL::BindIndexManager.new)
        render(redacted: true, bind_index_manager:)
      end

      # Returns typed placeholder values used by the SELECT query.
      #
      # @return [Hash{Symbol=>Object}] Placeholder values keyed by name.
      def placeholders
        ClickHouse::SQL.collect_placeholders(query_parts)
      end

      # Returns ClickHouse placeholder types used by the SELECT query.
      #
      # @return [Hash{Symbol=>String}] Placeholder types keyed by name.
      def placeholder_types
        ClickHouse::SQL.collect_placeholder_types(query_parts)
      end

      # Converts this builder into an immutable query object accepted by ClickHouse::HTTPClient.
      #
      # @return [ClickHouse::SQL::Query] Query object accepted by ClickHouse::HTTPClient.
      def to_query
        Query.new(
          sql: to_sql,
          redacted_sql: to_redacted_sql(Query.redacted_bind_index_manager),
          placeholders:,
          placeholder_types:
        )
      end

      private

      # Appends one clause entry: a single fragment (with optional positional
      # fills for anonymous `{}` slots and keyword placeholder bindings), an
      # array of fragments, or nil (appending nothing).
      def append_clause(target, condition, fills, bindings)
        case condition
        when nil, Array
          if fills.any? || bindings.any?
            raise Error, "Positional fills and keyword placeholder values require a single SQL string, got #{condition.class}"
          end

          Array(condition).flatten.compact.each { |fragment| target << ClickHouse::SQL.coerce_expression(fragment) }
        when String
          if fills.any? || bindings.any?
            target << Fragment.new(condition, bindings, fills:)
          else
            target << ClickHouse::SQL.coerce_expression(condition)
          end
        else
          if fills.any? || bindings.any?
            raise Error, "Positional fills and keyword placeholder values require a single SQL string, got #{condition.class}"
          end

          target << ClickHouse::SQL.coerce_expression(condition)
        end

        self
      end

      def append_raw_expressions(target, expressions)
        expressions.flatten.compact.each do |expression|
          target << ClickHouse::SQL.coerce_raw_expression(expression)
        end

        self
      end

      def one_fragment(expression, bindings)
        if bindings.any?
          raise Error, "Keyword placeholder values require a SQL fragment" unless expression

          Fragment.new(expression, bindings)
        elsif expression
          ClickHouse::SQL.coerce_expression(expression)
        end
      end

      def validate_settings!
        @settings.each do |setting|
          next unless setting.respond_to?(:placeholder_types)
          next if setting.placeholder_types.empty?

          raise Error, "ClickHouse SETTINGS do not support query parameters; use setting(name, value) for dynamic setting values"
        end
      end

      def render(redacted:, bind_index_manager: ClickHouse::SQL::BindIndexManager.new)
        raise Error, "SELECT requires at least one selected expression" if @selects.empty?
        raise Error, "SELECT requires a FROM clause" unless @from

        parts = []
        parts << render_with(redacted:, bind_index_manager:) if @with.any?
        parts << render_select(redacted:, bind_index_manager:)
        parts << render_from(redacted:, bind_index_manager:)
        parts.concat(@joins.map { |join| ClickHouse::SQL.render_part(join, redacted:, bind_index_manager:) })
        parts << render_conjunctive_clause("WHERE", @wheres, redacted:, bind_index_manager:) if @wheres.any?
        parts << render_list_clause("GROUP BY", @group_bys, redacted:, bind_index_manager:) if @group_bys.any?
        parts << render_conjunctive_clause("HAVING", @havings, redacted:, bind_index_manager:) if @havings.any?
        parts << render_list_clause("ORDER BY", @order_bys, redacted:, bind_index_manager:) if @order_bys.any?
        parts << "LIMIT #{ClickHouse::SQL.render_part(@limit, redacted:, bind_index_manager:)}" if @limit
        parts << "OFFSET #{ClickHouse::SQL.render_part(@offset, redacted:, bind_index_manager:)}" if @offset
        parts << render_list_clause("SETTINGS", @settings, redacted:, bind_index_manager:) if @settings.any?

        parts.join("\n")
      end

      def render_with(redacted:, bind_index_manager:)
        "WITH\n  #{@with.map { |part| ClickHouse::SQL.render_part(part, redacted:, bind_index_manager:) }.join(",\n  ")}"
      end

      def render_select(redacted:, bind_index_manager:)
        keyword = @distinct ? "SELECT DISTINCT" : "SELECT"
        "#{keyword}\n  #{@selects.map { |select| ClickHouse::SQL.render_part(select, redacted:, bind_index_manager:) }.join(",\n  ")}"
      end

      def render_from(redacted:, bind_index_manager:)
        sql = +"FROM #{ClickHouse::SQL.render_part(@from, redacted:, bind_index_manager:)}"
        sql << " FINAL" if @from_final
        sql << " AS #{ClickHouse::SQL.validate_alias!(@from_alias)}" if @from_alias
        sql
      end

      # Each condition is parenthesized so a condition containing a top-level
      # OR cannot change the meaning of the AND-joined clause.
      def render_conjunctive_clause(keyword, fragments, redacted:, bind_index_manager:)
        rendered = fragments.map { |fragment| "(#{ClickHouse::SQL.render_part(fragment, redacted:, bind_index_manager:)})" }
        "#{keyword}\n  #{rendered.join("\n  AND ")}"
      end

      def render_list_clause(keyword, fragments, redacted:, bind_index_manager:)
        rendered = fragments.map { |fragment| ClickHouse::SQL.render_part(fragment, redacted:, bind_index_manager:) }
        "#{keyword} #{rendered.join(', ')}"
      end

      def query_parts
        @selects + @with + [@from] + @joins + @wheres + @group_bys + @havings + @order_bys + [@limit, @offset] + @settings
      end
    end
  end
end
