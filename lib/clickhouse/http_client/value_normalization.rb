# frozen_string_literal: true

module ClickHouse
  module HTTPClient
    module ValueNormalization
      def self.symbolize_keys(hash)
        hash.transform_keys do |key|
          key.respond_to?(:to_sym) ? key.to_sym : key
        end
      end
    end
    private_constant :ValueNormalization
  end
end
