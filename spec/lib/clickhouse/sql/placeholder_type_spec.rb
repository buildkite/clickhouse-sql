# frozen_string_literal: true

require "spec_helper"

require_relative "../../../../lib/clickhouse/sql"

RSpec.describe ClickHouse::SQL::PlaceholderType do
  def validate(type, value)
    ClickHouse::SQL::PlaceholderType.new(type).validate_and_normalize(value)
  end

  it "validates signed integer boundaries" do
    expect(validate("Int8", -128)).to eq(-128)
    expect(validate("Int8", 127)).to eq(127)

    expect { validate("Int8", -129) }.to raise_error(ClickHouse::SQL::Error, /outside -128\.\.127/)
    expect { validate("Int8", 128) }.to raise_error(ClickHouse::SQL::Error, /outside -128\.\.127/)
  end

  it "validates unsigned integer boundaries" do
    expect(validate("UInt8", 0)).to eq(0)
    expect(validate("UInt8", 255)).to eq(255)

    expect { validate("UInt8", 256) }.to raise_error(ClickHouse::SQL::Error, /outside 0\.\.255/)
  end

  it "rejects floats and float strings for integer placeholders" do
    expect { validate("Int64", 1.5) }.to raise_error(ClickHouse::SQL::Error, /Integer placeholder requires/)
    expect { validate("UInt64", "1.5") }.to raise_error(ClickHouse::SQL::Error, /Integer placeholder requires/)
  end

  it "accepts integers and integer strings for unsized Integer placeholders" do
    expect(validate("Integer", 42)).to eq(42)
    expect(validate("Integer", "-42")).to eq(-42)
  end

  it "accepts finite numerics for float placeholders" do
    expect(validate("Float64", 1.5)).to eq(1.5)
    expect(validate("Float32", 1)).to eq(1)
  end

  it "rejects non-String values for String and FixedString placeholders" do
    expect(validate("FixedString(16)", "abc")).to eq("abc")

    expect { validate("String", 1) }.to raise_error(ClickHouse::SQL::Error, /String placeholder requires a String, got Integer/)
    expect { validate("String", :main) }.to raise_error(ClickHouse::SQL::Error, /String placeholder requires a String, got Symbol/)
    expect { validate("FixedString(16)", 1) }.to raise_error(ClickHouse::SQL::Error, /requires a String/)
  end

  it "accepts Date objects and ISO date strings for Date placeholders" do
    expect(validate("Date", Date.new(2026, 7, 1))).to eq(Date.new(2026, 7, 1))
    expect(validate("Date", "2026-07-01")).to eq("2026-07-01")

    expect { validate("Date", Time.utc(2026, 7, 1)) }.to raise_error(ClickHouse::SQL::Error, /Date placeholder requires/)
    expect { validate("Date", "2026-7-1") }.to raise_error(ClickHouse::SQL::Error, /Date placeholder requires/)

    # DateTime is a Date subclass but serializes with a time component,
    # which is not a valid ClickHouse Date literal.
    expect { validate("Date", DateTime.new(2026, 7, 1, 12)) }.to raise_error(ClickHouse::SQL::Error, /Date placeholder requires/)
  end

  it "passes String and Numeric values through for DateTime placeholders" do
    expect(validate("DateTime", "2026-07-01 12:00:00")).to eq("2026-07-01 12:00:00")
    expect(validate("DateTime", 1_751_328_000)).to eq(1_751_328_000)

    expect { validate("DateTime", :now) }.to raise_error(ClickHouse::SQL::Error, /DateTime placeholder requires/)
  end

  it "formats DateTime64 fractional seconds to the declared precision" do
    time = Time.utc(2026, 7, 1, 12, 0, 0, 123_456)

    expect(validate("DateTime64(0)", time)).to eq("2026-07-01 12:00:00")
    expect(validate("DateTime64(3)", time)).to eq("2026-07-01 12:00:00.123")
    expect(validate("DateTime64(9)", time)).to eq("2026-07-01 12:00:00.123456000")
  end

  it "unwraps Nullable and LowCardinality and validates the inner type" do
    uuid = "018f3f4a-8f58-7c3f-8b5c-0f6f30fd9ed1"

    expect(validate("Nullable(UUID)", uuid)).to eq(uuid)
    expect(validate("LowCardinality(String)", "main")).to eq("main")

    expect { validate("Nullable(UUID)", "not-a-uuid") }.to raise_error(ClickHouse::SQL::Error, /UUID-shaped/)
    expect { validate("LowCardinality(String)", 1) }.to raise_error(ClickHouse::SQL::Error, /requires a String/)
  end

  it "requires inner types for wrapper types" do
    expect { validate("Array", ["a"]) }.to raise_error(ClickHouse::SQL::Error, /Array placeholder requires an inner type/)
    expect { validate("Nullable", "a") }.to raise_error(ClickHouse::SQL::Error, /requires an inner type/)
  end

  it "validates nested array types recursively" do
    expect(validate("Array(Array(String))", [["a"], ["b", "c"]])).to eq([["a"], ["b", "c"]])

    expect { validate("Array(Array(String))", [["a"], "b"]) }.to raise_error(ClickHouse::SQL::Error, /Array placeholder requires an Array/)
  end

  it "passes values for unrecognized types through unvalidated" do
    # Intentional permissiveness: unknown ClickHouse types defer validation
    # to the server rather than rejecting types the builder doesn't know.
    expect(validate("Map(String, String)", { "a" => "b" })).to eq({ "a" => "b" })
    expect(validate("Bool", true)).to be(true)
  end

  it "accepts dots and hyphens in Identifier values" do
    expect(validate("Identifier", "http.method")).to eq("http.method")
    expect(validate("Identifier", "http-method")).to eq("http-method")
    expect(validate("Identifier", "a.b.c")).to eq("a.b.c")
  end

  it "accepts uppercase UUID values" do
    expect(validate("UUID", "018F3F4A-8F58-7C3F-8B5C-0F6F30FD9ED1")).to eq("018F3F4A-8F58-7C3F-8B5C-0F6F30FD9ED1")
  end

  it "rejects malformed type text" do
    expect { validate("123", 1) }.to raise_error(ClickHouse::SQL::Error, /Invalid ClickHouse placeholder type/)
  end
end
