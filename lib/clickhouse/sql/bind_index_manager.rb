# frozen_string_literal: true

module ClickHouse
  module SQL
    # Emits sequential `$1`-style bind markers when rendering redacted SQL,
    # so every typed placeholder in a query gets a stable positional marker
    # suitable for external log aggregation.
    #
    # Derived from GitLab's MIT-licensed click_house-client gem; see LICENSE.
    class BindIndexManager
      # @param start_index [Integer] Index of the first bind marker.
      def initialize(start_index = 1)
        @current_index = start_index
      end

      # Returns the next positional bind marker.
      #
      # @return [String] Bind marker such as `$1`.
      def next_bind_str
        bind_str = "$#{@current_index}"
        @current_index += 1
        bind_str
      end
    end
  end
end
