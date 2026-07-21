# ClickHouse::HTTPClient specs

Primary test coverage for `ClickHouse::HTTPClient` lives in
`spec/lib/clickhouse/http_client_spec.rb`, driving `.select`, `.execute`,
`.insert_csv`, and database registration through the public module API. Default
to adding new tests there, including for behavior implemented by internal
modules such as `ResponseFormatter`.

Specs in this directory exercise a nested constant directly only where that is
useful:

- `query_spec.rb` — `Query` is the caller-facing protocol object accepted by
  every query entry point.
- `parameter_serializer_spec.rb` — `ParameterSerializer` has a wide Ruby value
  × ClickHouse encoding matrix that is clearer to exercise directly.

Do not add per-module specs for the other internals unless their behavior is
impractical to exercise through the public API.
