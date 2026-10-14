# encoding: UTF-8
require "date"
source = File.expand_path("../../lib/tournaments/draft_details.rb", __dir__)
require source if File.file?(source)

class TournamentDraftDetailsTest
  def assert(value, message = "Niespełniona asercja")
    @assertions += 1
    raise message unless value
  end

  def equal(expected, actual)
    assert(expected == actual, "Oczekiwano #{expected.inspect}, otrzymano #{actual.inspect}")
  end

  def invalid(code, attributes)
    @assertions += 1
    begin
      GameRoomTournaments::DraftDetails.validate!(attributes)
    rescue GameRoomTournaments::DraftDetails::Invalid => error
      equal(code, error.code)
      assert(error.is_a?(ArgumentError))
      return
    end
    raise "Oczekiwano błędu #{code}: #{attributes.inspect}"
  end

  def validate(attributes)
    GameRoomTournaments::DraftDetails.validate!(attributes)
  end

  def test_defaults_validate_without_mutation_or_base_field_validation
    assert(defined?(GameRoomTournaments::DraftDetails), "Brak czystego walidatora DraftDetails")
    expected = {"participants" => [], "windows" => [], "players_per_match" => nil, "pairing" => nil,
      "group_count" => nil, "places_per_group" => nil, "group_advancement" => nil}
    equal(expected, GameRoomTournaments::DraftDetails::DEFAULTS)
    assert(GameRoomTournaments::DraftDetails::DEFAULTS.frozen?)
    assert(GameRoomTournaments::DraftDetails::DEFAULTS["participants"].frozen?)
    assert(GameRoomTournaments::DraftDetails::DEFAULTS["windows"].frozen?)
    input = {"name" => Object.new, "game_options" => :unrelated}.freeze
    keys = input.keys
    equal(true, validate(input))
    equal(keys, input.keys)
    equal(true, validate({}.freeze))
    equal(true, validate(expected.freeze))
  end

  def test_group_configuration_allows_incomplete_drafts_but_rejects_invalid_types
    equal(true, validate('group_count' => 2, 'places_per_group' => 1))
    equal(true, validate('group_count' => 128, 'places_per_group' => 255))
    [1, 129, '2', 2.0, true].each { |value| invalid(:invalid_group_configuration, 'group_count' => value) }
    [0, 256, '1', 1.0, false].each { |value| invalid(:invalid_group_configuration, 'places_per_group' => value) }
  end

  def test_participants_keep_order_spelling_and_inputs
    names = ["Żółć", "ALFA", "two words", "a".b, "😀" * 64].map(&:freeze).freeze
    input = {"participants" => names}.freeze
    equal(true, validate(input))
    equal(["Żółć", "ALFA", "two words", "a", "😀" * 64], input["participants"])
    equal(true, validate("participants" => Array.new(256) { |i| "Gracz #{i}" }))
  end

  {
    nil_value: nil, string: "Ala", hash: {}, symbol: :players, number: 3,
    too_many: Array.new(257) { |i| "Gracz #{i}" }, empty_name: [""],
    long_name: ["ą" * 65], non_string: [1], nil_name: [nil], nested: [["Ala"]],
    leading_space: [" Ala"], trailing_space: ["Ala "], nbsp: ["Ala\u00a0"],
    ideographic_space: ["\u3000Ala"], newline: ["Al\na"], tab: ["Al\ta"],
    null: ["Al\0a"], delete: ["Al\u007fa"], c1: ["Al\u0085a"],
    line_separator: ["Al\u2028a"], paragraph_separator: ["Al\u2029a"],
    invalid_utf8: ["\xff".force_encoding("UTF-8")], binary: ["\xff".b],
    utf16: ["Ala".encode("UTF-16LE")], duplicate: ["Ala", "Ala"],
    duplicate_case: ["ALA", "Ala"], duplicate_unicode: ["ŻÓŁĆ", "żółć"]
  }.each do |label, value|
    define_method("test_participants_reject_#{label}") { invalid(:invalid_participants, "participants" => value) }
  end

  def window(overrides = {})
    {"date" => "2026-10-01", "start" => "18:00", "end_date" => "2026-10-01", "end" => "21:00"}.merge(overrides)
  end

  def test_windows_accept_civil_gregorian_limits_and_preserve_order
    windows = [window, window("date" => "0001-01-01", "end_date" => "0001-01-01", "start" => "00:00", "end" => "00:01"),
      window("date" => "9999-12-31", "end_date" => "9999-12-31", "end" => "23:59"),
      window("date" => "1582-10-10", "end_date" => "1582-10-10"),
      window("date" => "2000-02-29", "end_date" => "2000-03-01", "start" => "23:00", "end" => "01:00"),
      window("date" => "2026-03-29", "end_date" => "2026-03-29", "start" => "02:15", "end" => "02:30")]
    windows.each { |item| item.each_value(&:freeze); item.freeze }
    windows.freeze
    equal(true, validate("windows" => windows))
    equal("2026-10-01", windows.first["date"])
    equal(true, validate("windows" => Array.new(366) { |i|
      date = (Date.new(2024, 1, 1, Date::GREGORIAN) + i).strftime("%Y-%m-%d")
      window("date" => date, "end_date" => date)
    }.reverse))
    equal(true, validate("windows" => [window("start" => "21:00", "end" => "22:00"), window]))
  end

  {
    nil_value: nil, string: "18-21", hash: {}, number: 3, boolean: false,
    many: Array.new(367, {}), nil_record: [nil], array_record: [[]], empty_record: [{}]
  }.each do |label, value|
    define_method("test_windows_reject_#{label}") { invalid(:invalid_windows, "windows" => value) }
  end

  %w[date start end_date end].each do |field|
    define_method("test_windows_reject_missing_#{field}") do
      invalid(:invalid_windows, "windows" => [window.reject { |key, _| key == field }])
    end
    define_method("test_windows_reject_symbol_#{field}") do
      record = window
      record[field.to_sym] = record.delete(field)
      invalid(:invalid_windows, "windows" => [record])
    end
  end

  %w[date end_date].each do |field|
    [nil, 20261001, false, [], {}, "2026-2-01", "2026-02-1", "26-02-01", "0000-01-01", "10000-01-01",
      "2026-00-01", "2026-13-01", "2026-01-00", "2026-01-32", "2026-04-31", "2026-02-29",
      "1900-02-29", "1500-02-29", "2026-10-01\n", " 2026-10-01", "2026-10-01Z", "２０２６-10-01",
      "\xff".force_encoding("UTF-8"), "2026-10-01".encode("UTF-16LE")].each_with_index do |value, index|
      define_method("test_windows_reject_#{field}_#{index}") do
        invalid(:invalid_windows, "windows" => [window(field => value)])
      end
    end
  end

  %w[start end].each do |field|
    [nil, 1800, false, [], {}, "9:00", "18:0", "24:00", "23:60", "-1:00", "18:00:00", "18:00Z",
      "18:00\n", " 18:00", "１８:00", "\xff".b, "18:00".encode("UTF-16LE")].each_with_index do |value, index|
      define_method("test_windows_reject_#{field}_#{index}") do
        invalid(:invalid_windows, "windows" => [window(field => value)])
      end
    end
  end

  def test_windows_reject_extra_keys
    invalid(:invalid_windows, "windows" => [window("timezone" => "Europe/Warsaw")])
  end

  def test_windows_reject_equal_endpoints
    invalid(:invalid_windows, "windows" => [window("end" => "18:00")])
  end

  def test_windows_reject_backwards_time
    invalid(:invalid_windows, "windows" => [window("end" => "17:59")])
  end

  def test_windows_reject_backwards_date
    invalid(:invalid_windows, "windows" => [window("end_date" => "2026-09-30")])
  end

  def test_windows_reject_duplicates
    invalid(:invalid_windows, "windows" => [window, window])
  end

  def test_windows_reject_unsorted_overlap
    invalid(:invalid_windows, "windows" => [window("start" => "20:59", "end" => "23:00"), window])
  end

  def test_windows_reject_contained_interval
    invalid(:invalid_windows, "windows" => [window, window("start" => "19:00", "end" => "20:00")])
  end

  def test_windows_reject_overnight_overlap
    invalid(:invalid_windows, "windows" => [window("date" => "2026-09-30", "end" => "18:01"), window])
  end

  def test_players_per_match_requires_nil_or_integer_between_two_and_eight
    [nil, *(2..8)].each { |value| equal(true, validate("players_per_match" => value)) }
    [0, 1, 9, -2, 2.0, "2", true, false, [], {}, :two].each do |value|
      invalid(:invalid_players_per_match, "players_per_match" => value)
    end
  end

  def test_pairing_requires_known_string_without_coercion
    [nil, "all_combinations", "balanced_cycle"].each { |value| equal(true, validate("pairing" => value)) }
    ["", "ALL_COMBINATIONS", "balanced_cycle ", :all_combinations, 1, true, false, [], {},
      "\xff".b, "all_combinations".encode("UTF-16LE")].each do |value|
      invalid(:invalid_pairing, "pairing" => value)
    end
  end

  def run
    @assertions = 0
    failures = []
    cases = methods.grep(/^test_/).sort
    cases = cases.select { |name| name.to_s.include?(ARGV.fetch(1)) } if ARGV.first == "--only"
    raise "Nie wybrano testów" if cases.empty?
    cases.each do |name|
      begin
        send(name)
        puts "PASS #{name}"
      rescue StandardError => error
        failures << name
        warn "FAIL #{name}: #{error.class}: #{error.message}\n#{error.backtrace.first(4).join("\n")}"
      end
    end
    puts "Przypadki: #{cases.length}; asercje: #{@assertions}; błędy: #{failures.length}"
    failures.empty?
  end
end

exit(TournamentDraftDetailsTest.new.run ? 0 : 1) if $PROGRAM_NAME == __FILE__
