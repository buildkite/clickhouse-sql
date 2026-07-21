# clickhouse-sql

`clickhouse-sql` provides a typed `ClickHouse::SQL` query builder and the
`ClickHouse::HTTPClient` transport for ClickHouse. It keeps SQL visible while
binding runtime values through ClickHouse named typed placeholders.

The gem supports Ruby 3.4 and later and has no runtime gem dependencies.

## Installation

Add the gem to your bundle:

```ruby
gem "clickhouse-sql"
```

Then run `bundle install` and load both public components:

```ruby
require "clickhouse-sql"
```

Applications that need only one component can load it independently:

```ruby
require "clickhouse/sql"
# or
require "clickhouse/http_client"
```

The SQL builder and HTTP client interoperate through query objects responding
to `#to_sql` and `#placeholders`; neither component requires a framework.

## Security and trust model

**All runtime or untrusted values belong in named typed placeholders.** Plain
SQL strings, fragment slots, table names, `raw_static`, and `unsafe_raw` are
trusted SQL structure. Never interpolate request parameters, user input, or
other untrusted values into them.

```ruby
# Safe: the value is serialized separately as param_account_id.
query.where("{} = {account_id:UUID}", events[:account_id], account_id: account_id)

# Unsafe: account_id becomes executable SQL structure.
query.where("account_id = '#{account_id}'")
```

`raw_static` is for compile-time or allowlisted structure. `unsafe_raw` requires
a reason to make exceptional use reviewable, but the reason is advisory: the
gem does not inspect or sanitize the supplied SQL. Query-level settings are
rendered into SQL rather than sent as placeholders, so setting names and values
may appear in logs or instrumentation.

An opted-in instrumenter receives the full query object, including its SQL text
and raw placeholder values. Treat instrumentation backends and subscribers as
sensitive-data sinks, and do not attach an instrumenter that cannot safely
handle the values your application queries.

Outside local development, use a TLS (`https://`) ClickHouse endpoint and a
least-privilege ClickHouse user restricted to the databases, tables, and query
operations the application needs.

## HTTPClient

`ClickHouse::HTTPClient` registers ClickHouse databases and executes queries
over HTTP. It exposes `select`, `execute`, and `insert_csv`; each accepts an
optional per-query `timeout:`.

### Database registration

Register connections during application initialization. Registry names are
process-global, and duplicate names raise
`ClickHouse::HTTPClient::ConfigurationError`.

```ruby
require "clickhouse-sql"
require "logger"

ClickHouse::HTTPClient.logger = Logger.new($stdout)
ClickHouse::HTTPClient.register_database(
  :analytics,
  database: "default",
  url: ENV.fetch("CLICKHOUSE_URL", "http://localhost:8123"),
  username: ENV.fetch("CLICKHOUSE_USERNAME", "default"),
  password: ENV.fetch("CLICKHOUSE_PASSWORD", ""),
  variables: { max_execution_time: 30 },
)
```

The client uses a two-second connection-open timeout and a 30-second request
timeout by default. A query-specific `timeout:` replaces the request timeout:

```ruby
rows = ClickHouse::HTTPClient.select("SELECT 1 AS value", :analytics, timeout: 5)
# => [{ "value" => 1 }]
```

Plain query strings are accepted as trusted SQL. To bind values without the
SQL builder, use the transport query object:

```ruby
query = ClickHouse::HTTPClient::Query.new(
  sql: "SELECT {id:UInt64} AS id",
  placeholders: { id: 42 },
)

rows = ClickHouse::HTTPClient.select(query, :analytics)
```

Passing a `ClickHouse::SQL` builder directly compiles it through `#to_query`,
so builder validation still runs:

```ruby
query = ClickHouse::SQL
  .select("id", "name")
  .from("events")
  .where("id = {id:UInt64}", id: 42)

rows = ClickHouse::HTTPClient.select(query, :analytics)
```

`select` returns an array of string-keyed hashes. It typecasts integer and
float widths, `Date`/`Date32`, UTC `DateTime`/`DateTime64`,
`IntervalSecond`/`IntervalMillisecond`, and
arrays of supported types. UTC datetimes become UTC Ruby `Time` values;
`IntervalSecond` is integer seconds and `IntervalMillisecond` is floating-point
seconds. Non-UTC datetimes and unrecognized types, including `Map` and `Tuple`
internals, pass through as parsed from JSON. Zone-less `DateTime` values are
treated as UTC, so the ClickHouse server should use UTC as its default timezone.

### Commands and CSV insertion

`execute` and `insert_csv` return an immutable `ExecutionResult`. Failures
raise rather than returning a failed result.

```ruby
result = ClickHouse::HTTPClient.execute(
  "CREATE TABLE IF NOT EXISTS events (id UInt64) ENGINE = MergeTree ORDER BY id",
  :analytics,
)

result.query_id   # server query ID, or nil if the server omitted it
result.statistics # symbol-keyed final summary, or {}
```

`insert_csv` streams a gzip-compressed IO as a chunked request. The SQL must not
contain placeholders because the request body is occupied by CSV data.

```ruby
require "stringio"
require "zlib"

compressed = StringIO.new
gzip = Zlib::GzipWriter.new(compressed)
gzip.write("1,created\n2,updated\n")
gzip.finish
compressed.rewind

result = ClickHouse::HTTPClient.insert_csv(
  "INSERT INTO events (id, name) FORMAT CSV",
  compressed,
  :analytics,
)

result.statistics.fetch(:written_rows)
```

### Errors

Failures raise subclasses of `ClickHouse::HTTPClient::Error`:

- `DatabaseError` for ClickHouse error responses;
- `ConnectionError` for connection and protocol failures;
- `TimeoutError` for client-side request timeouts;
- `QueryError` for query-protocol misuse; and
- `ConfigurationError` for database registry problems.

Transport errors retain the underlying standard-library exception as their
cause. A server-side `max_execution_time` kill is a `DatabaseError` mentioning
`TIMEOUT_EXCEEDED`, not a client-side `TimeoutError`.

`nil` placeholder values are sent as `NULL`. ClickHouse rejects `NULL` for most
non-Nullable types but can parse it as an empty string for a plain `String`
placeholder. `ClickHouse::SQL` validates nil values against placeholder types
before execution to close that gap.

### Logging and instrumentation

Set any logger responding to `#debug`:

```ruby
ClickHouse::HTTPClient.logger = Logger.new($stdout)
```

Instrumentation is opt-in. Supply an object implementing
`instrument(name, payload) { |mutable_payload| ... }`. It must yield exactly
once and propagate exceptions. The payload initially contains `:query` and
`:database`; the client adds `:query_id` and `:statistics` as they become
available.

```ruby
instrumenter = Object.new
def instrumenter.instrument(name, payload)
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield payload
ensure
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  warn({ event: name, elapsed: elapsed, payload: payload }.inspect)
end

ClickHouse::HTTPClient.instrumenter = instrumenter
```

The default instrumenter is a no-op. Framework integrations belong in the host
application; for example, an application that already uses Active Support may
assign `ActiveSupport::Notifications` because it implements this protocol.
Remember that the payload exposes raw placeholder values as described in the
security section.

## SQL

`ClickHouse::SQL` is a small, clause-oriented builder for ClickHouse `SELECT`
queries. It builds mutable SQL objects that compose safely, then compiles them
with `#to_query` into immutable HTTP-client-compatible query objects. It is not
an ORM: callers still choose exact select lists and map returned rows into
their own objects.

### Quick example

```ruby
CH = ClickHouse::SQL

events = CH.table("events")
accounts = CH.table("accounts", as: "a")

query = CH
  .select(events.columns(:id, :timestamp, :duration), accounts[:status])
  .from(events)
  .left_join(accounts, final: true, on: [
    CH.fragment("{} = {}", accounts[:id], events[:account_id]),
  ])
  .where("{} = {account_id:UUID}", events[:account_id], account_id: account_id)
  .where("{} IN {categories:Array(String)}", events[:category], categories: categories)
  .where("{}.{tag_key:Identifier} = {tag_value:String}", events[:tags], tag_key: "geo.country", tag_value: "AU")
  .order_by("timestamp DESC")
  .limit("{limit:UInt32}", limit: 100)

rows = ClickHouse::HTTPClient.select(query, :analytics)
```

Table handles build qualified column references. Passing the aliased
`accounts` handle to `left_join` renders `LEFT JOIN accounts FINAL AS a`, and
every `accounts[...]` reference renders with the `a` qualifier. Plain SQL such
as `order_by("timestamp DESC")` is accepted as trusted structure where no
qualification is needed.

### Typed placeholders

Use ClickHouse named typed placeholders for values known only at runtime:

```ruby
CH.fragment("account_id = {account_id:UUID}", account_id: account_id)
CH.fragment("account_id IN {account_ids:Array(UUID)}", account_ids: account_ids)
CH.fragment("timestamp >= {from:DateTime64(6)}", from: from_time)
CH.fragment("tags.{tag_key:Identifier} = {value:String}", tag_key: "geo.country", value: "AU")
```

The declared ClickHouse type is the source of truth. The builder validates
supported types such as `UUID`, `Array(T)`, `Nullable(T)`, `Identifier`, `Date`,
`DateTime`, `DateTime64(N)`, signed and unsigned integers, and floats before
the client sends the query.

### Fragment slots

Inside a fragment, `{name:Type}` is a ClickHouse value placeholder. Untyped
braces are local slots for trusted SQL objects. Anonymous `{}` slots are filled
in source order by positional arguments:

```ruby
CH.fragment("{} = {}", accounts[:id], events[:account_id])
CH.fragment("{} = {account_id:UUID}", events[:account_id], account_id: account_id)
```

Named `{name}` slots are filled by keyword argument:

```ruby
tag_column = CH.raw_static("events.tags")

CH.fragment(
  "{tag_column}.{tag_key:Identifier}::Nullable(String)",
  tag_column: tag_column,
  tag_key: "triage.reason",
)
```

Fragment slots accept SQL fragments, raw/static fragments, nested builders,
table/column handles, and compiled SQL queries. They do not accept arbitrary
runtime strings or unrelated query objects.

### Query composition

`ClickHouse::SQL.select` returns a mutable, chainable `SelectQuery`. Its clause
methods accept trusted SQL strings or fragments, positional fills for anonymous
slots, keyword values for typed placeholders, or arrays of fragments:

- `with` and `with_cte`;
- `from` and `from_subquery`;
- `join`, `left_join`, `inner_join`, and `joins`;
- `where`, `having`, `group_by`, and `order_by`;
- `limit` and `offset`; and
- `settings` and `setting`.

Repeated `where`/`having` conditions and multiple join `on:` conditions are
`AND`-joined with every condition parenthesized. A condition containing a
top-level `OR` therefore cannot change the meaning of adjacent conditions.
`CH.and` and `CH.or` provide the same parenthesized composition, while `CH.csv`
and `CH.parens` handle small expression lists.

`CH.bind_list` generates one typed placeholder per item when a single
`Array(T)` parameter could exceed ClickHouse's per-field size limit
(`http_max_field_value_size`, 128 KiB by default):

```ruby
ids = CH.bind_list(:account_id, account_ids, type: "UUID")
query.where(CH.fragment("{} IN ({})", events[:account_id], ids))
```

### Table handles, CTEs, and derived tables

Table handles validate table names and qualify columns, preventing ambiguity
when joined tables share column names:

```ruby
events = CH.table("events")
accounts = CH.table("accounts", as: "a")

CH.select(events[:id], accounts[:name])
  .from(events)
  .left_join(accounts, on: [
    CH.fragment("{} = {}", accounts[:id], events[:account_id]),
  ])
  .where("{} >= {from:DateTime64(6)}", events[:timestamp], from: from_time)
```

Column references use the alias when present (`a.name`) and otherwise the table
name (`events.id`). Names interpolate into raw SQL, so each dot-separated
segment must be a simple identifier. Hyphenated names such as tag keys belong
in `{name:Identifier}` placeholders instead. Nested paths such as
`events["tags.client.version"]` are supported.

A handle owns its alias. Passing `as:` alongside a handle raises, even if the
aliases match. `as:` on `from`/`join` is only for string table names.

Handles also keep CTE and derived-table references consistent:

```ruby
filtered = CH.table("filtered")
filtered_query = CH.select("id", "timestamp").from("events")

with_cte = CH.select(filtered[:id])
  .with_cte(filtered, filtered_query)
  .from(filtered)

from_subquery = CH.select(filtered[:id])
  .from_subquery(filtered_query, as: filtered)
```

In fragment slots, a table handle renders as its table name, not its qualifier.
Use `table[:column]` or `table.qualifier` inside expressions rather than
`{table}.column`.

### Settings

ClickHouse does not parameterize query-level settings. Use `setting` for a
validated name and value, or `settings` only for fixed, trusted fragments:

```ruby
query
  .setting(:max_threads, 4)
  .setting(:use_query_cache, false)
```

String setting values are escaped as ClickHouse string literals, but they are
still rendered into the query. Do not put secrets or untrusted structure in
settings; their values may be visible in SQL logs and instrumenter payloads.

### Trusted and unsafe raw SQL

`CH.raw_static(sql)` is for compile-time or allowlisted SQL structure such as
`*`, fixed table names, fixed expressions, or fixed sort directions. It does
not collect placeholder values.

`CH.unsafe_raw(sql, reason:)` is an explicit escape hatch for trusted ClickHouse
syntax that cannot be represented with placeholders, such as a fixed
`INTERVAL` literal in `WITH FILL`. Always provide a durable reason, and never
use this method to bypass value binding.

### Known parser limitations

Fragment parsing treats every `{...}` in fragment SQL as a placeholder; it is
not aware of SQL string literals or comments. SQL containing literal braces —
for example `match(col, 'a{2,3}')` or `{'a': 1}` — raises
`ClickHouse::SQL::Error` (or treats a brace-wrapped bare identifier as a
fragment slot). Wrap a fixed, trusted expression containing literal braces in
`raw_static` or `unsafe_raw` so it is not parsed for placeholders.

Compact `CH.bind_list` names use `"#{prefix}#{index.to_s(36)}"` without a
separator. Two lists whose prefixes overlap can generate the same name (`:t`
at index 36 and `:t1` at index 0 both produce `t10`). A collision raises when
values differ but coalesces when they are equal. Within one query, use prefixes
that do not end in digits and are not prefixes of one another.

## Package contents

The published gem is intended to contain only Ruby files under `lib/` plus
`README.md`, `LICENSE`, and `CHANGELOG.md`. Development tools and tests are not
runtime dependencies or package contents.

## Attribution

Parts of `ClickHouse::HTTPClient` are derived from GitLab's MIT-licensed
[click_house-client](https://gitlab.com/gitlab-org/gitlab/-/tree/e9d4efda854653515bf3aab0e8c2441976f83c9f/gems/click_house-client)
gem — thanks to GitLab for publishing it under a permissive license. See
[LICENSE](LICENSE) for the full notice. The `ClickHouse::SQL` query builder is
original to this gem.
