# encoding: UTF-8
require_relative '../support/assertions'
require_relative '../support/elten_array_shuffle'
source = File.expand_path('../../lib/tournaments/league_plan.rb', __dir__)
require source if File.file?(source)

module LeaguePlanTest
  extend GameRoomTest::Assertions
  @passed = 0

  def self.test(name)
    yield
    @passed += 1
    puts "PASS #{name}"
  end

  def self.build(participants: %w[A B C D], players_per_match: 2,
    pairing: 'all_combinations', rematch: false)
    GameRoomTournaments::LeaguePlan.build(participants: participants,
      players_per_match: players_per_match, pairing: pairing, rematch: rematch)
  end

  def self.invalid(code, **attributes)
    error = assert_raises(ArgumentError) { build(**attributes) }
    assert_equal('GameRoomTournaments::LeaguePlan::Invalid', error.class.name)
    assert_equal(code, error.code)
  end

  def self.finish
    puts "PASS #{@passed} scenariuszy planera turnieju każdy z każdym"
  end
end

LeaguePlanTest.test('two-player league contains every pair once for both explicit pairings') do
  LeaguePlanTest.assert(defined?(GameRoomTournaments::LeaguePlan), 'Missing local league planner')
  expected = [%w[A B], %w[A C], %w[A D], %w[B C], %w[B D], %w[C D]]
  %w[all_combinations balanced_cycle].each do |pairing|
    plan = LeaguePlanTest.build(pairing: pairing)
    LeaguePlanTest.assert_equal(expected.each_with_index.map { |players, index|
      { 'number' => index + 1, 'players' => players, 'leg' => 1 }
    }, plan)
  end
end

LeaguePlanTest.test('three-player full league contains all unique compositions in input order') do
  expected = [%w[A B C], %w[A B D], %w[A B E], %w[A C D], %w[A C E],
    %w[A D E], %w[B C D], %w[B C E], %w[B D E], %w[C D E]]
  plan = LeaguePlanTest.build(participants: %w[A B C D E], players_per_match: 3)
  LeaguePlanTest.assert_equal(expected, plan.map { |match| match['players'] })
end

LeaguePlanTest.test('balanced cycles wrap the input list and give each person three appearances') do
  names = %w[A B C D E]
  expected = [%w[A B C], %w[B C D], %w[C D E], %w[D E A], %w[E A B]]
  plan = LeaguePlanTest.build(participants: names, players_per_match: 3, pairing: 'balanced_cycle')
  LeaguePlanTest.assert_equal(expected, plan.map { |match| match['players'] })
  LeaguePlanTest.assert_equal(names.to_h { |name| [name, 3] }, plan.flat_map { |match| match['players'] }.tally)
end

LeaguePlanTest.test('exactly k participants produce just one match for k = 2 through 8') do
  (2..8).each do |k|
    names = Array.new(k) { |index| "Player #{index + 1}" }
    %w[all_combinations balanced_cycle].each do |pairing|
      LeaguePlanTest.assert_equal([{ 'number' => 1, 'players' => names, 'leg' => 1 }],
        LeaguePlanTest.build(participants: names, players_per_match: k, pairing: pairing))
    end
  end
end

LeaguePlanTest.test('four through eight players support full combinations and equal-appearance cycles') do
  (4..8).each do |k|
    names = Array.new(k + 2) { |index| "Player #{index + 1}" }
    complete = LeaguePlanTest.build(participants: names, players_per_match: k)
    # Wybór k spośród k+2 odpowiada wybraniu pominiętej pary.
    expected = names.each_with_index.flat_map do |first, index|
      names[(index + 1)..].map { |second| names - [first, second] }
    end
    LeaguePlanTest.assert_equal(expected.sort, complete.map { |match| match['players'] }.sort)
    cycle = LeaguePlanTest.build(participants: names, players_per_match: k, pairing: 'balanced_cycle')
    LeaguePlanTest.assert_equal(names.length, cycle.length)
    LeaguePlanTest.assert_equal(names.length, cycle.map { |match| match['players'].sort }.uniq.length)
    LeaguePlanTest.assert(cycle.all? { |match| match['players'].uniq.length == k })
    LeaguePlanTest.assert_equal(names.to_h { |name| [name, k] }, cycle.flat_map { |match| match['players'] }.tally)
  end
end

LeaguePlanTest.test('rematches are a complete second leg with precisely the same compositions') do
  (2..8).each do |k|
    [k, k + 2].each do |n|
      names = Array.new(n) { |index| "Player #{index + 1}" }
      %w[all_combinations balanced_cycle].each do |pairing|
        single = LeaguePlanTest.build(participants: names, players_per_match: k, pairing: pairing)
        double = LeaguePlanTest.build(participants: names, players_per_match: k, pairing: pairing, rematch: true)
        LeaguePlanTest.assert_equal(single.length * 2, double.length)
        LeaguePlanTest.assert_equal(single, double.first(single.length))
        LeaguePlanTest.assert_equal(single.map { |match| match['players'].sort },
          double.drop(single.length).map { |match| match['players'].sort })
        LeaguePlanTest.assert_equal([1] * single.length + [2] * single.length, double.map { |match| match['leg'] })
        LeaguePlanTest.assert_equal((1..double.length).to_a, double.map { |match| match['number'] })
        LeaguePlanTest.assert(double.map { |match| match['players'].sort }.tally.values.all? { |count| count == 2 })
      end
    end
  end
end

LeaguePlanTest.test('pairing and rematch must be explicit organizer choices, even for two players') do
  LeaguePlanTest.invalid(:missing_pairing, pairing: nil)
  LeaguePlanTest.invalid(:missing_rematch, rematch: nil)
  hostile = Object.new
  def hostile.==(_other); true; end
  def hostile.to_str; raise 'Do not coerce organizer choices'; end
  [false, true, '', 'round_robin', 'groups_knockout', :all_combinations, 2, [], {}, hostile,
    "\xFF".b, 'all_combinations'.encode('UTF-16LE')].each do |value|
    LeaguePlanTest.invalid(:invalid_pairing, pairing: value)
  end
  ['', 'false', 'true', 0, 1, [], {}, hostile].each do |value|
    LeaguePlanTest.invalid(:invalid_rematch, rematch: value)
  end
end

LeaguePlanTest.test('participants must be a bounded array, not coercible or enumerable input') do
  hostile = Object.new
  def hostile.to_ary; raise 'Do not coerce participants'; end
  def hostile.each; raise 'Do not enumerate non-arrays'; end
  [nil, false, 'Alice', {}, hostile, [], ['Alice'], Array.new(257) { |index| "Player #{index}" }].each do |value|
    LeaguePlanTest.invalid(:invalid_participants, participants: value)
  end
end

LeaguePlanTest.test('nazwy uczestników są tekstem od 1 do 64 znaków, bez konwersji typów') do
  hostile = Object.new
  def hostile.to_str; raise 'Nie konwertuj nazwy na String'; end
  def hostile.to_s; raise 'Nie konwertuj nazwy na tekst'; end
  [nil, false, true, 7, :Alice, [], {}, hostile, '', 'A' * 65, 'Ż' * 65].each do |value|
    LeaguePlanTest.invalid(:invalid_participants, participants: [value, 'Bob'])
  end
  names = ['Ż' * 64, 'A']
  LeaguePlanTest.assert_equal(names, LeaguePlanTest.build(participants: names).first['players'])
end

LeaguePlanTest.test('nazwy dopuszczają UTF-8 lub poprawne ASCII w kodowaniu zgodnym z ASCII') do
  invalid_names = ["\xFF".force_encoding('UTF-8'), "\xC5".force_encoding('UTF-8'),
    "\xFF".b, 'Żaneta'.b, 'Łukasz'.encode('Windows-1250'),
    'Alice'.encode('UTF-16LE'), 'Alice'.encode('UTF-32BE'),
    "\xFF".force_encoding('US-ASCII')]
  invalid_names.each do |name|
    LeaguePlanTest.invalid(:invalid_participants, participants: [name, 'Bob'])
  end
  ['UTF-8', 'US-ASCII', 'ASCII-8BIT', 'ISO-8859-2', 'Windows-1250', 'Shift_JIS'].each do |encoding|
    name = 'Alice'.encode(encoding)
    actual = LeaguePlanTest.build(participants: [name, 'Żaneta']).first['players']
    LeaguePlanTest.assert_equal([name, 'Żaneta'], actual)
    LeaguePlanTest.assert_equal(encoding, actual.first.encoding.name)
  end
end

LeaguePlanTest.test('nazwy odrzucają znaki sterujące, separatory wierszy i zewnętrzne białe znaki') do
  controls = (0..31).to_a + (127..159).to_a + [0x2028, 0x2029]
  controls.each do |point|
    LeaguePlanTest.invalid(:invalid_participants, participants: ["A#{point.chr(Encoding::UTF_8)}B", 'Bob'])
  end
  [" ", "\t", "\n", "\u00A0", "\u1680", "\u2003", "\u202F", "\u205F", "\u3000"].each do |space|
    [space, "#{space}Alice", "Alice#{space}"].each do |name|
      LeaguePlanTest.invalid(:invalid_participants, participants: [name, 'Bob'])
    end
  end
  names = ['Ala Nowak', "Jan\u00A0Kowalski"]
  LeaguePlanTest.assert_equal(names, LeaguePlanTest.build(participants: names).first['players'])
end

LeaguePlanTest.test('nazwy są unikalne po downcase także dla UTF-8 i mieszanych etykiet ASCII') do
  [%w[Alice Alice], %w[Alice ALICE], %w[Żaneta żaneta], %w[ŁUKASZ łukasz],
    ['Alice'.b, 'alice'.encode('Shift_JIS')]].each do |names|
    LeaguePlanTest.invalid(:invalid_participants, participants: names)
  end
  names = ['Żaneta', 'Zaneta']
  LeaguePlanTest.assert_equal(names, LeaguePlanTest.build(participants: names).first['players'])
end

LeaguePlanTest.test('rozmiar stołu jest Integer od 2 do 8 i nie przekracza liczby uczestników') do
  hostile = Object.new
  def hostile.to_int; raise 'Nie konwertuj rozmiaru stołu'; end
  def hostile.to_i; raise 'Nie konwertuj rozmiaru stołu'; end
  def hostile.>(other); raise 'Nie porównuj obcego typu'; end
  def hostile.between?(*bounds); true; end
  %w[all_combinations balanced_cycle].each do |pairing|
    [nil, false, true, '2', 2.0, Rational(2, 1), :two, [], {}, hostile,
      -1, 0, 1, 5, 8, 9, 10**100].each do |value|
      LeaguePlanTest.invalid(:invalid_players_per_match, players_per_match: value, pairing: pairing)
    end
  end
end

LeaguePlanTest.test('limit jest sprawdzany przed wywołaniem combination, także przy 256 uczestnikach') do
  blocked = Class.new(Array) do
    def combination(*)
      raise 'Nie wolno wyliczać składów po przekroczeniu limitu'
    end
  end
  [[101, 2], [33, 3], [21, 4], [17, 5], [15, 6], [15, 7], [15, 8], [256, 8]].each do |n, k|
    names = blocked.new(n) { |index| "Gracz #{index}" }
    LeaguePlanTest.invalid(:too_many_matches, participants: names, players_per_match: k)
    if k == 2
      LeaguePlanTest.invalid(:too_many_matches, participants: names, players_per_match: k, pairing: 'balanced_cycle')
    end
  end
end

LeaguePlanTest.test('limit całego planu obejmuje rewanże przed enumeracją pierwszej części') do
  blocked = Class.new(Array) do
    def combination(*)
      raise 'Limit rewanżów musi być sprawdzony przed pierwszą kombinacją'
    end
  end
  [[72, 2], [26, 3], [18, 4], [15, 5], [14, 6], [14, 7], [14, 8]].each do |n, k|
    names = blocked.new(n) { |index| "Gracz #{index}" }
    LeaguePlanTest.invalid(:too_many_matches, participants: names, players_per_match: k, rematch: true)
    if k == 2
      LeaguePlanTest.invalid(:too_many_matches, participants: names, players_per_match: k,
        pairing: 'balanced_cycle', rematch: true)
    end
  end
  [[false, [[100, 2, 4950], [32, 3, 4960], [20, 4, 4845], [16, 5, 4368],
    [14, 6, 3003], [14, 7, 3432], [14, 8, 3003]]],
    [true, [[71, 2, 4970], [25, 3, 4600], [17, 4, 4760], [14, 5, 4004],
    [13, 6, 3432], [13, 7, 3432], [13, 8, 2574]]]].each do |rematch, boundaries|
    boundaries.each do |n, k, expected|
      names = Array.new(n) { |index| "Gracz #{index}" }
      plan = LeaguePlanTest.build(participants: names, players_per_match: k, rematch: rematch)
      LeaguePlanTest.assert_equal(expected, plan.length)
      LeaguePlanTest.assert_equal((1..expected).to_a, plan.map { |match| match['number'] })
      LeaguePlanTest.assert_equal(rematch ? 2 : 1, plan.last['leg'])
      if k == 2
        LeaguePlanTest.assert_equal(plan, LeaguePlanTest.build(participants: names, players_per_match: k,
          pairing: 'balanced_cycle', rematch: rematch))
      end
    end
  end
end

LeaguePlanTest.test('każde spotkanie i rewanż mają własną tablicę oraz niezależne kopie nazw') do
  (2..8).each do |k|
    %w[all_combinations balanced_cycle].each do |pairing|
      [false, true].each do |rematch|
        names = Array.new(k + 2) { |index| "Gracz #{index}" }
        original = names.map(&:dup)
        plan = LeaguePlanTest.build(participants: names, players_per_match: k, pairing: pairing, rematch: rematch)
        again = LeaguePlanTest.build(participants: names, players_per_match: k, pairing: pairing, rematch: rematch)
        LeaguePlanTest.assert_equal(original, names)
        LeaguePlanTest.assert_equal(plan, again)
        arrays = [names] + (plan + again).map { |match| match['players'] }
        LeaguePlanTest.assert_equal(arrays.length, arrays.map(&:object_id).uniq.length)
        strings = arrays.flatten
        LeaguePlanTest.assert_equal(strings.length, strings.map(&:object_id).uniq.length)
        plan.first['players'].first.replace('Zmieniona nazwa w meczu')
        LeaguePlanTest.assert_equal(original, names)
        LeaguePlanTest.assert_equal(again.drop(1), plan.drop(1))
        LeaguePlanTest.assert_equal(original.first(k), again.first['players'])
        plan.first['players'].clear
        LeaguePlanTest.assert_equal(again.drop(1), plan.drop(1))
        names.first.replace('Zmieniona nazwa na wejściu')
        names.clear
        LeaguePlanTest.assert_equal(original.first(k), again.first['players'])
        LeaguePlanTest.assert_equal(again.drop(1), plan.drop(1))
      end
    end
  end
end

LeaguePlanTest.test('obcy obiekt nie podszywa się pod typ, nil ani wartość logiczną') do
  hostile = Object.new
  def hostile.is_a?(_type); true; end
  def hostile.equal?(_other); true; end
  def hostile.nil?; true; end
  def hostile.length; raise 'Nie odczytuj długości obcego typu'; end
  def hostile.to_ary; raise 'Nie konwertuj tablicy'; end
  def hostile.to_str; raise 'Nie konwertuj tekstu'; end
  def hostile.to_int; raise 'Nie konwertuj liczby'; end
  LeaguePlanTest.invalid(:invalid_participants, participants: hostile)
  LeaguePlanTest.invalid(:invalid_participants, participants: [hostile, 'Bob'])
  LeaguePlanTest.invalid(:invalid_players_per_match, players_per_match: hostile)
  LeaguePlanTest.invalid(:invalid_pairing, pairing: hostile)
  LeaguePlanTest.invalid(:invalid_rematch, rematch: hostile)
end

LeaguePlanTest.test('wybór algorytmu wynika z treści tekstu, nie nadpisanego operatora porównania') do
  misleading = Class.new(String) do
    def ==(_other); true; end
  end
  %w[all_combinations balanced_cycle].each do |pairing|
    expected = LeaguePlanTest.build(participants: %w[A B C D E], players_per_match: 3, pairing: pairing)
    actual = LeaguePlanTest.build(participants: %w[A B C D E], players_per_match: 3,
      pairing: misleading.new(pairing))
    LeaguePlanTest.assert_equal(expected, actual)
  end
end

LeaguePlanTest.test('cykl przy 256 uczestnikach jest deterministyczny, równy i nie losuje') do
  names = Array.new(256) { |index| "Gracz #{index}".freeze }.freeze
  guard = TracePoint.new(:call, :c_call) do |event|
    if [:shuffle, :shuffle!, :rand, :srand].include?(event.method_id)
      raise 'Czysty planner nie może korzystać z losowania ani tasowania'
    end
  end
  (3..8).each do |k|
    plan = guard.enable do
      first = LeaguePlanTest.build(participants: names, players_per_match: k, pairing: 'balanced_cycle', rematch: true)
      second = LeaguePlanTest.build(participants: names, players_per_match: k, pairing: 'balanced_cycle', rematch: true)
      LeaguePlanTest.assert_equal(first, second)
      first
    end
    LeaguePlanTest.assert_equal(512, plan.length)
    LeaguePlanTest.assert_equal((1..512).to_a, plan.map { |match| match['number'] })
    LeaguePlanTest.assert_equal([1] * 256 + [2] * 256, plan.map { |match| match['leg'] })
    LeaguePlanTest.assert_equal(names.to_h { |name| [name, k * 2] }, plan.flat_map { |match| match['players'] }.tally)
    LeaguePlanTest.assert_equal(names.first(k), plan.first['players'])
    LeaguePlanTest.assert_equal([names.last] + names.first(k - 1), plan[255]['players'])
    LeaguePlanTest.assert_equal(plan.first(256).map { |match| match['players'] },
      plan.drop(256).map { |match| match['players'] })
    LeaguePlanTest.assert(plan.all? { |match| match['players'].uniq.length == k })
    LeaguePlanTest.assert_equal(256, plan.first(256).map { |match| match['players'].sort }.uniq.length)
    plan.first['players'].first.replace('Zmieniona kopia zamrożonej nazwy')
    LeaguePlanTest.assert_equal('Gracz 0', names.first)
    LeaguePlanTest.assert_equal('Gracz 0', plan[256]['players'].first)
  end
end

LeaguePlanTest.finish
