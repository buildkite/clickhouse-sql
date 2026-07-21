# frozen_string_literal: true

module ClickHouse
  module HTTPClient
    module ValueNormalization
      def self.symbolize_keys(hash)
        hash.transform_keys do |key|
          key.respond_to?(:to_sym) ? key.to_sym : key
        end
      end

      # Recursively copies and freezes Arrays, Hashes, and Strings so a
      # value can be held without observing callers' later mutations.
      def self.immutable_copy(value)
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
    end
    private_constant :ValueNormalization
  end
end
