# frozen_string_literal: true

module ClickHouse
  module SQL
    class Fragment
      include Part

      # Builds a composable SQL fragment with typed placeholders and slots.
      #
      # @param sql [String, #to_s] SQL containing `{name:Type}` values, `{name}`
      #   slots, and/or anonymous `{}` slots.
      # @param bindings [Hash{Symbol,String=>Object}] Named placeholder and slot bindings.
      # @param fills [Array<ClickHouse::SQL::Part>] Positional fills for anonymous
      #   `{}` slots in source order.
      # @return [ClickHouse::SQL::Fragment] A validated fragment.
      def initialize(sql, bindings = {}, fills: [])
        raise Error, "Empty SQL fragment given" if ValueNormalization.blank_string?(sql)

        @sql = sql.to_s
        @bindings = ValueNormalization.symbolize_keys(bindings || {})
        @fills = Array(fills)
        @placeholders = ClickHouse::SQL.parse_placeholders(@sql)

        validate_fills!
        validate_bindings!
      end

      # Renders the fragment with ClickHouse typed placeholders intact.
      #
      # @return [String] SQL fragment text.
      def to_sql
        render(redacted: false)
      end

      # Renders the fragment with typed placeholders replaced by bind markers.
      #
      # @param bind_index_manager [ClickHouse::SQL::BindIndexManager] Redacted bind index state.
      # @return [String] Redacted SQL fragment text.
      def to_redacted_sql(bind_index_manager = ClickHouse::SQL::BindIndexManager.new)
        render(redacted: true, bind_index_manager:)
      end

      # Returns typed placeholder values from this fragment and nested slots.
      #
      # @return [Hash{Symbol=>Object}] Placeholder values keyed by name.
      def placeholders
        ClickHouse::SQL.merge_placeholders!(@typed_placeholder_values.dup, nested_placeholders)
      end

      # Returns ClickHouse placeholder types from this fragment and nested slots.
      #
      # @return [Hash{Symbol=>String}] Placeholder types keyed by name.
      def placeholder_types
        ClickHouse::SQL.merge_placeholder_types!(@placeholder_types.dup, nested_placeholder_types)
      end

      private

      attr_reader :bindings

      def validate_fills!
        anonymous = @placeholders.select(&:anonymous?)
        unless anonymous.length == @fills.length
          raise Error, "Fragment has #{anonymous.length} anonymous {} slots but #{@fills.length} positional fills were given"
        end

        @fills.each do |fill|
          next if ClickHouse::SQL.part?(fill)

          raise Error, "Anonymous fragment slot {} requires a SQL fragment, got #{fill.class}"
        end

        @fill_by_position = anonymous.map(&:begin_pos).zip(@fills).to_h
      end

      def validate_bindings!
        named = @placeholders.reject(&:anonymous?)
        used_names = named.map(&:name_sym)
        unused_names = bindings.keys - used_names
        raise Error, "Unused ClickHouse placeholder values: #{unused_names.join(', ')}" if unused_names.any?

        typed_names = named.select(&:typed?).map(&:name_sym)
        slot_names = named.reject(&:typed?).map(&:name_sym)
        collisions = typed_names & slot_names
        raise Error, "Placeholder names cannot be both typed values and fragment slots: #{collisions.join(', ')}" if collisions.any?

        missing_names = used_names.uniq - bindings.keys
        raise Error, "Missing ClickHouse placeholder values: #{missing_names.join(', ')}" if missing_names.any?

        @typed_placeholder_values = {}
        @placeholder_types = {}

        named.select(&:typed?).each do |placeholder|
          type = PlaceholderType.new(placeholder.type)
          value = type.validate_and_normalize(bindings.fetch(placeholder.name_sym))

          register_typed_placeholder!(placeholder.name_sym, type.normalized, value)
        end

        named.reject(&:typed?).each do |placeholder|
          value = bindings.fetch(placeholder.name_sym)
          next if ClickHouse::SQL.part?(value)

          raise Error, "Fragment slot {#{placeholder.name}} requires a SQL fragment, got #{value.class}"
        end
      end

      def register_typed_placeholder!(name, type, value)
        if @placeholder_types.key?(name)
          unless @placeholder_types.fetch(name) == type
            raise Error, "mismatching types for the '#{name}' placeholder: #{@placeholder_types.fetch(name)} vs #{type}"
          end

          unless @typed_placeholder_values.fetch(name) == value
            raise Error, "mismatching values for the '#{name}' placeholder: " \
              "#{ClickHouse::SQL.truncated_inspect(@typed_placeholder_values.fetch(name))} vs #{ClickHouse::SQL.truncated_inspect(value)}"
          end
        end

        @placeholder_types[name] = type
        @typed_placeholder_values[name] = value
      end

      # Returns nested slot parts (anonymous fills and named slot values) in source order.
      def slot_parts
        @placeholders.reject(&:typed?).map { |placeholder| slot_part(placeholder) }
      end

      def slot_part(placeholder)
        if placeholder.anonymous?
          @fill_by_position.fetch(placeholder.begin_pos)
        else
          bindings.fetch(placeholder.name_sym)
        end
      end

      def nested_placeholders
        slot_parts.each_with_object({}) do |part, values|
          ClickHouse::SQL.merge_placeholders!(values, part.placeholders)
        end
      end

      def nested_placeholder_types
        slot_parts.each_with_object({}) do |part, types|
          ClickHouse::SQL.merge_placeholder_types!(types, part.placeholder_types)
        end
      end

      def render(redacted:, bind_index_manager: ClickHouse::SQL::BindIndexManager.new)
        rendered = +""
        last_pos = 0

        @placeholders.each do |placeholder|
          rendered << @sql[last_pos...placeholder.begin_pos]
          rendered << render_placeholder(placeholder, redacted:, bind_index_manager:)
          last_pos = placeholder.end_pos
        end

        rendered << @sql[last_pos..].to_s
      end

      def render_placeholder(placeholder, redacted:, bind_index_manager:)
        if placeholder.typed?
          redacted ? bind_index_manager.next_bind_str : placeholder.raw
        else
          ClickHouse::SQL.render_part(slot_part(placeholder), redacted:, bind_index_manager:)
        end
      end
    end
  end
end
