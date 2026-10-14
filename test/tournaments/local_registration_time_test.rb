# encoding: UTF-8
require_relative '../support/assertions'
source = File.expand_path('../../lib/tournaments/local_registration_time.rb', __dir__)
require source if File.file?(source)

module TournamentLocalRegistrationTimeTest
  extend GameRoomTest::Assertions
  module_function

  def test_01_rzeczywisty_systemowy_roundtrip
    assert(defined?(GameRoomTournaments::LocalRegistrationTime), 'Brak LocalRegistrationTime')
    actual = GameRoomTournaments::LocalRegistrationTime.convert('2026-02-15', '12:00')
    assert(actual.is_a?(Integer) && actual >= 0)
    local = Time.at(actual).getlocal
    assert_equal([2026, 2, 15, 12, 0, 0], [local.year, local.month, local.day, local.hour, local.min, local.sec])
    assert_equal(Time.local(2026, 2, 15, 12, 0, 0).to_i, actual)
  end
  def test_02_scisle_formaty_gregorianski_dzien_i_nieujemna_epoka
    helper = GameRoomTournaments::LocalRegistrationTime
    assert(defined?(helper::Invalid), 'Brak kontrolowanej walidacji czasu')
    [nil, 12, '', '2026-2-15', '2026-02-1', ' 2026-02-15', "2026-02-15\n", '0000-02-15',
      '10000-01-01', '2026-02-29', '1900-02-29', '2026-04-31', '2026-00-10'].each do |date|
      assert_equal(:invalid_date, assert_raises(helper::Invalid) { helper.convert(date, '12:00') }.code)
    end
    [nil, 12, '', '1:00', '12:0', ' 12:00', "12:00\n", '24:00', '12:60', '12:00:00'].each do |time|
      assert_equal(:invalid_time, assert_raises(helper::Invalid) { helper.convert('2026-02-15', time) }.code)
    end
    result = helper.convert('2000-02-29', '12:00')
    assert_equal([2000, 2, 29, 12, 0, 0], Time.at(result).getlocal.to_a.values_at(5, 4, 3, 2, 1, 0))
    assert_equal(:invalid_timestamp, assert_raises(helper::Invalid) { helper.convert('1969-01-01', '12:00') }.code)
    date, time = +'2026-02-15', +'12:34'
    helper.convert(date, time)
    assert_equal('2026-02-15', date)
    assert_equal('12:34', time)
    assert(!date.frozen? && !time.frozen?)
  end
  # Syntetyczny zegar reguł DST: to NIE jest dowód ustawień strefy Windows.
  # Używa tylko Time.utc / getlocal(jawny offset); nie zmienia globalnego TZ.
  class SyntheticTime
    Stamp = Struct.new(:local_time) do
      def getlocal; local_time; end
    end
    attr_reader :local_calls

    def initialize(preferred = 7200)
      @preferred, @local_calls = preferred, []
      @spring = Time.utc(2026, 3, 29, 1, 0, 0).to_i
      @autumn = Time.utc(2026, 10, 25, 1, 0, 0).to_i
    end

    def utc(*parts); Time.utc(*parts); end

    def at(seconds)
      offset = seconds >= @spring && seconds < @autumn ? 7200 : 3600
      Stamp.new(Time.at(seconds).getlocal(offset))
    end

    def local(*parts)
      @local_calls << parts
      civil = Time.utc(*parts).to_i
      options = [@preferred, 10_800 - @preferred].map { |offset| at(civil - offset).getlocal }
      options.find { |time| time.to_a.values_at(5, 4, 3, 2, 1, 0) == parts } || at(civil - 3600).getlocal
    end
  end

  def test_03_syntetyczny_dst_jednoznaczny_niejednoznaczny_i_luka
    helper = GameRoomTournaments::LocalRegistrationTime
    [3600, 7200].each do |preferred|
      adapter = SyntheticTime.new(preferred)
      error = assert_raises(helper::Invalid) { helper.convert('2026-10-25', '02:30', time_adapter: adapter) }
      assert_equal(:ambiguous_time, error.code)
      assert(error.message.include?('Choose another time'))
      error = assert_raises(helper::Invalid) { helper.convert('2026-03-29', '02:30', time_adapter: adapter) }
      assert_equal(:nonexistent_time, error.code)
      assert_equal(Time.utc(2026, 7, 1, 10).to_i, helper.convert('2026-07-01', '12:00', time_adapter: adapter))
      assert_equal(Time.utc(2026, 12, 1, 11).to_i, helper.convert('2026-12-01', '12:00', time_adapter: adapter))
      assert(adapter.local_calls.all? { |parts| parts.last == 0 })
    end
  end

  def test_05_explicit_utc_preserves_dst_gap_and_fold_instants
    helper = GameRoomTournaments::LocalRegistrationTime
    # These civil hours are ambiguous/nonexistent in some local zones, but
    # explicit UTC is independent of their DST rules.
    [['2026-03-29', '02:30'], ['2026-10-25', '02:30']].each do |date, time|
      value = helper.convert_utc(date, time)
      assert_equal("#{date} #{time}", Time.at(value).utc.strftime('%Y-%m-%d %H:%M'))
      assert_equal(value, Time.at(value).getlocal('-05:00').to_i)
      assert_equal(value, Time.at(value).getlocal('+14:00').to_i)
    end
    assert_equal(0, helper.convert_utc('1970-01-01', '00:00'))
    assert_equal(:invalid_timestamp, assert_raises(helper::Invalid) { helper.convert_utc('1969-12-31', '23:59') }.code)
    assert_equal(:invalid_date, assert_raises(helper::Invalid) { helper.convert_utc('2026-02-29', '12:00') }.code)
    assert_equal(:invalid_time, assert_raises(helper::Invalid) { helper.convert_utc('2026-02-28', '24:00') }.code)
  end

  def test_04_nieobslugiwany_zegar_fail_closed_bledy_programu_jawne
    helper = GameRoomTournaments::LocalRegistrationTime
    [:local, :at, :utc].each do |method|
      adapter = SyntheticTime.new
      adapter.define_singleton_method(method) { |*| raise RangeError, 'Brak reprezentacji w platformie' }
      assert_equal(:unsupported_time, assert_raises(helper::Invalid) {
        helper.convert('2026-07-01', '12:00', time_adapter: adapter)
      }.code)
    end
    adapter = SyntheticTime.new
    adapter.define_singleton_method(:local) { |*| raise NoMethodError, 'Błąd programu' }
    assert_raises(NoMethodError) { helper.convert('2026-07-01', '12:00', time_adapter: adapter) }
    adapter = SyntheticTime.new
    result = helper.convert('9999-12-31', '12:00', time_adapter: adapter)
    assert_equal(9999, adapter.at(result).getlocal.year)
    assert_equal(:invalid_timestamp, assert_raises(helper::Invalid) {
      helper.convert('0001-01-01', '12:00', time_adapter: adapter)
    }.code)
  end
end

TournamentLocalRegistrationTimeTest.singleton_methods.grep(/^test_/).sort.each do |name|
  TournamentLocalRegistrationTimeTest.public_send(name)
  puts "PASS #{name}"
end
