# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClickHouse::HTTPClient::ParameterSerializer do
  it "handles simple string" do
    expect(serialize("hello")).to eq("hello")
  end

  it "handles string with single-quote" do
    expect(serialize("g'day")).to eq("g'day")
  end

  it "escapes backslashes in top-level strings" do
    # ClickHouse decodes backslash sequences in top-level parameter values
    # (escaped text format), so an unescaped "C:\temp" would arrive as
    # "C:<TAB>emp".
    expect(serialize("C:\\temp")).to eq("C:\\\\temp")
    expect(serialize("Company\\Product")).to eq("Company\\\\Product")
  end

  it "escapes tabs, newlines, and carriage returns in top-level strings" do
    # A literal TAB or LF byte terminates escaped-text String parsing,
    # making the whole query fail with BAD_QUERY_PARAMETER.
    expect(serialize("a\tb")).to eq('a\tb')
    expect(serialize("line one\nline two")).to eq('line one\nline two')
    expect(serialize("a\rb")).to eq('a\rb')
  end

  it "escapes a literal backslash-N string so it is not read as NULL" do
    expect(serialize("\\N")).to eq("\\\\N")
  end

  it "escapes symbols like strings" do
    expect(serialize(:"a\tb")).to eq('a\tb')
  end

  it "handles integer" do
    expect(serialize(1234)).to eq("1234")
  end

  it "handles float" do
    expect(serialize(1.234)).to eq("1.234")
  end

  it "handles boolean" do
    expect(serialize(true)).to eq("true")
    expect(serialize(false)).to eq("false")
  end

  it "handles top-level nil as the escaped text format NULL" do
    expect(serialize(nil)).to eq("\\N")
  end

  it "handles nested nil as the NULL literal" do
    # Inside Array/Map literals ClickHouse expects the NULL keyword;
    # the top-level \N escape is rejected by the literal parser.
    expect(serialize([nil])).to eq("[NULL]")
  end

  it "handles array mixing values and nils" do
    expect(serialize(["a", nil, "b"])).to eq("['a',NULL,'b']")
  end

  it "handles Hash (Map) with nil values" do
    expect(serialize({ one: 1, two: nil })).to eq("{'one':1,'two':NULL}")
  end

  it "handles nils in nested arrays" do
    expect(serialize([["a", nil], [nil]])).to eq("[['a',NULL],[NULL]]")
  end

  it "handles array of integers" do
    expect(serialize([1, 2, 3])).to eq("[1,2,3]")
  end

  it "handles array of strings" do
    expect(serialize(["hello", "world"])).to eq("['hello','world']")
  end

  it "handles array of strings with single quotes and backslashes" do
    expect(serialize(["g'day", "wor\\d"])).to eq("['g\\'day','wor\\\\d']")
  end

  it "handles nested arrays" do
    expect(serialize([["running", "canceling"], ["scheduled"]])).to eq("[['running','canceling'],['scheduled']]")
  end

  it "handles time ala date_time_input_format=basic" do
    t = Time.zone.parse("2025-05-07 17:27:42.123")
    expect(serialize(t)).to eq("2025-05-07 17:27:42")
  end

  it "converts zoned times to UTC" do
    # ClickHouse interprets rendered DateTime text in the placeholder's (or
    # server's) timezone, so only UTC wall-clock text is safe to send.
    melbourne = Time.find_zone!("Australia/Melbourne").parse("2025-05-07 17:27:42")
    expect(serialize(melbourne)).to eq("2025-05-07 07:27:42")

    offset = Time.new(2025, 5, 7, 17, 27, 42, "+10:00")
    expect(serialize(offset)).to eq("2025-05-07 07:27:42")
  end

  it "handles date" do
    expect(serialize(Date.parse("2025-05-07"))).to eq("2025-05-07")
  end

  it "handles array of times" do
    times = [
      Time.zone.parse("2025-05-07 17:27:42.123"),
      Time.zone.parse("2025-05-08 00:00:00.000"),
    ]
    expect(serialize(times)).to eq("['2025-05-07 17:27:42','2025-05-08 00:00:00']")
  end

  it "handles array of dates" do
    dates = [
      Date.parse("2025-05-07"),
      Date.parse("2025-05-08"),
    ]
    expect(serialize(dates)).to eq("['2025-05-07','2025-05-08']")
  end

  it "handles Hash (Map)" do
    expect(serialize({ one: 1, two: 2 })).to eq("{'one':1,'two':2}")
  end

  it "handles Hash (Map) of Array" do
    input = { "one" => ["A", "a"], "two" => ["B", "b"] }
    expect(serialize(input)).to eq("{'one':['A','a'],'two':['B','b']}")
  end

  def serialize(...) = described_class.serialize(...)
end
