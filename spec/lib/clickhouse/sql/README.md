# ClickHouse::SQL specs

Primary test coverage for `ClickHouse::SQL` lives in `spec/lib/clickhouse/sql_spec.rb`,
driving the public module API (`ClickHouse::SQL.fragment`, `.select`, `.table`, …)
as a black box. Default to adding new tests there — including for behavior
implemented in internal classes like `Fragment`, `Join`, and `Raw`.

Specs in this directory construct a class directly, and exist only where that
is justified:

- `placeholder_type_spec.rb` — `PlaceholderType` has a wide type × value
  validation matrix that is impractical to exercise through the facade.
- `query_spec.rb` — `Query` is the protocol object accepted by
  `ClickHouse::HTTPClient`, with defensive checks unreachable via the builder.

Do not add per-class specs for the other internals; they are implementation
details, and testing them directly couples the suite to the current structure.
