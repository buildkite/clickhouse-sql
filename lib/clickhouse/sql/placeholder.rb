# frozen_string_literal: true

module ClickHouse
  module SQL
    # A parsed `{name}`, `{name:Type}`, or anonymous `{}` placeholder from a
    # SQL fragment.
    #
    # @!attribute raw
    #   @return [String] The placeholder text including braces.
    # @!attribute name
    #   @return [String, nil] Placeholder name, or nil for anonymous `{}` slots.
    # @!attribute type
    #   @return [String, nil] ClickHouse type text, or nil for fragment slots.
    # @!attribute begin_pos
    #   @return [Integer] Start offset in the source SQL.
    # @!attribute end_pos
    #   @return [Integer] End offset in the source SQL.
    Placeholder = Struct.new(:raw, :name, :type, :begin_pos, :end_pos, keyword_init: true) do
      # Returns whether this placeholder is a ClickHouse typed value.
      #
      # @return [Boolean] True for `{name:Type}`, false for fragment slots.
      def typed?
        !ValueNormalization.blank_string?(type)
      end

      # Returns whether this placeholder is an anonymous `{}` fragment slot.
      #
      # @return [Boolean] True for `{}`, false for named placeholders.
      def anonymous?
        name.nil?
      end

      # Returns the placeholder name as a symbol.
      #
      # @return [Symbol, nil] Symbolized placeholder name, or nil for anonymous slots.
      def name_sym
        name&.to_sym
      end
    end
  end
end
