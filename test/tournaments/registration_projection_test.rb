# encoding: UTF-8
require 'json'
require_relative '../support/assertions'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/publication'
source = File.expand_path('../../lib/tournaments/registration_projection.rb', __dir__)
require source if File.file?(source)

module RegistrationProjectionTest
  extend GameRoomTest::Assertions
  module_function

  def test(name)
    yield
    puts JSON.generate({ 'pass' => name }, ascii_only: true)
  end

  def announcement(id = 10, author = 'Organizator', key = 'publication-1')
    draft = { 'name' => 'Turniej', 'game_id' => 'chess', 'game_options' => {},
      'format' => 'round_robin', 'rematch' => false, 'players_per_match' => 2,
      'pairing' => 'balanced_cycle',
      'windows' => [{ 'date' => '2026-10-15', 'start' => '12:00', 'end_date' => '2026-10-15', 'end' => '21:00' }] }
    GameRoomTournaments::Publication.from_draft(draft: draft, registry: GameRoomGames::CATALOG,
      publication_key: key, rules: 'Regulamin.', registration_opens_at: 100,
      registration_closes_at: 200, timezone: 'Europe/Warsaw').to_row.merge(
        '__id' => id, '__insertion_user' => author, '__insertion_time' => 90)
  end

  def join(id = 1, user = 'Żaneta', time = 150, key = 'op-1', tournament = 10)
    { '__id' => id, '__insertion_user' => user, '__insertion_time' => time,
      'tournament_id' => tournament, 'operation_key' => key, 'kind' => 'join' }
  end

  def build(rows, announcements: [announcement], complete: true)
    GameRoomTournaments::RegistrationProjection.build(announcements: announcements,
      registrations: rows, registry: GameRoomGames::CATALOG, complete: complete)
  end
end

RegistrationProjectionTest.test('dwa konta dopisują join bez wspólnego rosteru i obecności organizatora') do
  include GameRoomTest::Assertions
  assert(defined?(GameRoomTournaments::RegistrationProjection), 'Brak modelu RegistrationProjection')
  assert_equal({ 'tournament_id' => 10, 'operation_key' => 'op-1', 'kind' => 'join' },
    GameRoomTournaments::RegistrationProjection.join_values(tournament_id: 10, operation_key: 'op-1'))
  projection = RegistrationProjectionTest.build([RegistrationProjectionTest.join,
    RegistrationProjectionTest.join(2, 'Bartek')])
  assert_equal(%w[bartek żaneta], projection.to_h['members'].map { |member| member['account'] }.sort)
  assert_equal([10], projection.to_h['members'].map { |member| member['tournament_id'] }.uniq)
  assert_equal('confirmed', projection.operation_status(tournament_id: 10, account: 'ŻANETA', operation_key: 'op-1'))
  assert_equal('unconfirmed', projection.operation_status(tournament_id: 10, account: 'Nieobecny', operation_key: 'op-1'))
end

RegistrationProjectionTest.test('Unicode, podwójny join i retry dają jedno konto i zachowują dowody operacji') do
  rows = [RegistrationProjectionTest.join(4, 'ŻANETA', 140),
    RegistrationProjectionTest.join(2, 'żaneta', 120), RegistrationProjectionTest.join(8, 'Żaneta', 160, 'op-2'),
    RegistrationProjectionTest.join(9, 'Zaneta', 150)]
  projection = RegistrationProjectionTest.build(rows)
  members = projection.to_h['members']
  assert_equal(2, members.size)
  member = members.find { |item| item['account'] == 'żaneta' }
  assert_equal(2, member['registration_id'])
  assert_equal(120, member['joined_at'])
  operation = projection.to_h['operations'].find { |item| item['account'] == 'żaneta' && item['operation_key'] == 'op-1' }
  assert_equal([2, 4], operation['record_ids'])
  rows.permutation.each { |order| assert_equal(projection.to_h, RegistrationProjectionTest.build(order).to_h) }
  assert_equal('confirmed', projection.operation_status(tournament_id: 10, account: 'ŻANETA', operation_key: 'op-2'))
end

RegistrationProjectionTest.test('join powiązany z aliasem tego samego ogłoszenia nie ginie') do
  announcements = [RegistrationProjectionTest.announcement(30), RegistrationProjectionTest.announcement(10),
    RegistrationProjectionTest.announcement(40, 'Inny organizator')]
  rows = [RegistrationProjectionTest.join(1, 'Ala', 130, 'one', 30),
    RegistrationProjectionTest.join(2, 'Ala', 140, 'one', 10),
    RegistrationProjectionTest.join(3, 'Bartek', 150, 'two', 40)]
  projection = RegistrationProjectionTest.build(rows, announcements: announcements)
  assert_equal([10, 40], projection.to_h['members'].map { |item| item['tournament_id'] })
  assert_equal('confirmed', projection.operation_status(tournament_id: 30, account: 'ala', operation_key: 'one'))
  assert_equal('unconfirmed', projection.operation_status(tournament_id: 40, account: 'ala', operation_key: 'one'))
  assert_equal(projection.to_h, RegistrationProjectionTest.build(rows.reverse, announcements: announcements.reverse).to_h)
end

RegistrationProjectionTest.test('czas serwerowy obowiązuje w półotwartym przedziale i także przy retry') do
  [99, 100, 101, 199, 200, 201].each do |time|
    projection = RegistrationProjectionTest.build([RegistrationProjectionTest.join(1, 'Ala', time)])
    accepted = time >= 100 && time < 200
    assert_equal(accepted ? 1 : 0, projection.to_h['members'].size)
    assert_equal(accepted ? 'confirmed' : 'outside_window',
      projection.operation_status(tournament_id: 10, account: 'Ala', operation_key: 'op-1'))
  end
  rows = [RegistrationProjectionTest.join(1, 'Ala', 99), RegistrationProjectionTest.join(2, 'Ala', 100),
    RegistrationProjectionTest.join(3, 'Ala', 200)]
  projection = RegistrationProjectionTest.build(rows)
  assert_equal(2, projection.to_h['members'].first['registration_id'])
  assert_equal([1, 2, 3], projection.to_h['operations'].first['record_ids'])
  assert_equal([2], projection.to_h['operations'].first['eligible_ids'])
end

RegistrationProjectionTest.test('nick z payload nie jest uprawnieniem, a brak metadanych nie potwierdza zapisu') do
  base = RegistrationProjectionTest.join.merge('username' => 'Ofiara', 'actor' => 'Ofiara', 'nick' => 'Ofiara',
    'created_at' => 150, 'id' => 1)
  projection = RegistrationProjectionTest.build([base])
  assert_equal('żaneta', projection.to_h['members'].first['account'])
  { '__id' => [nil, '1', 1.0, 0, false], '__insertion_time' => [nil, '150', 150.0, -1, false],
    '__insertion_user' => [nil, '', ' Ala', 3, "\xFF".b, "A\nB"] }.each do |field, values|
    values.each do |value|
      result = RegistrationProjectionTest.build([base.merge(field => value)])
      assert_equal([], result.to_h['members'])
      assert_equal('unconfirmed', result.operation_status(tournament_id: 10, account: 'Żaneta', operation_key: 'op-1'))
      assert(!result.to_h['diagnostics']['registrations'].empty?)
    end
  end
  late = base.merge('__insertion_time' => 201, 'created_at' => 150)
  assert_equal([], RegistrationProjectionTest.build([late]).to_h['members'])
end

RegistrationProjectionTest.test('konflikt ID, klucza i niepoprawny wiersz izolują grupę bez cichego nadpisania') do
  base = RegistrationProjectionTest.join
  other = RegistrationProjectionTest.join(99, 'Inne konto', 150, 'other')
  conflicts = [base.merge('__insertion_user' => 'Ktoś'), base.merge('__insertion_time' => 151),
    base.merge('operation_key' => 'another'), base.merge('kind' => 'close'),
    base.merge('__id' => 2, 'kind' => 'withdraw'), base.merge('__id' => 2, 'tournament_id' => 20),
    base.merge('__id' => 2, '__insertion_time' => nil)]
  announcements = [RegistrationProjectionTest.announcement, RegistrationProjectionTest.announcement(20, 'Inny')]
  conflicts.each do |bad|
    result = RegistrationProjectionTest.build([base, bad, other], announcements: announcements)
    assert_equal(['inne konto'], result.to_h['members'].map { |item| item['account'] })
    assert_equal('conflict', result.operation_status(tournament_id: 10, account: 'Żaneta', operation_key: 'op-1'))
    assert_equal(result.to_h, RegistrationProjectionTest.build([other, bad, base], announcements: announcements).to_h)
  end
  invalids = [nil, false, 'śmieć', {}, base.merge('__id' => 3, 'tournament_id' => 900, 'operation_key' => 'unknown'),
    base.merge('__id' => 5, 'kind' => 'close', 'operation_key' => 'close')]
  result = RegistrationProjectionTest.build(invalids + [other])
  assert_equal(['inne konto'], result.to_h['members'].map { |item| item['account'] })
  corrupt = RegistrationProjectionTest.announcement(11).merge('title' => 'Inne warunki')
  result = RegistrationProjectionTest.build([base], announcements: [RegistrationProjectionTest.announcement, corrupt])
  assert_equal([], result.to_h['members'])
end

RegistrationProjectionTest.test('wejścia nie są mutowane i całe publiczne wyniki są głęboko zamrożone') do
  rows = [RegistrationProjectionTest.join]
  announcements = [RegistrationProjectionTest.announcement]
  before = Marshal.dump([rows, announcements])
  projection = RegistrationProjectionTest.build(rows, announcements: announcements)
  assert_equal(before, Marshal.dump([rows, announcements]))
  assert_raises(FrozenError) { projection.to_h['members'].first['account'].clear }
  assert_raises(FrozenError) { projection.to_h['operations'].first['record_ids'].clear }
  assert_raises(FrozenError) { projection.to_h['diagnostics']['registrations'] << {} }
  assert(projection.frozen?)
  rows.first['__insertion_user'].clear
  announcements.clear
  assert_equal('confirmed', projection.operation_status(tournament_id: 10, account: 'Żaneta', operation_key: 'op-1'))
  assert_equal('żaneta', projection.to_h['members'].first['account'])
end

RegistrationProjectionTest.test('budżety i niepełny odczyt są błędem całej projekcji, nie częściowym rosterem') do
  assert_raises(GameRoomTournaments::Publication::Incomplete) do
    RegistrationProjectionTest.build([RegistrationProjectionTest.join], complete: false)
  end
  assert_raises(GameRoomTournaments::Publication::Incomplete) do
    RegistrationProjectionTest.build(Array.new(4097, RegistrationProjectionTest.join))
  end
  [nil, '1', 1.0, 0, -1].each do |id|
    assert_raises(GameRoomTournaments::Publication::Invalid) do
      GameRoomTournaments::RegistrationProjection.join_values(tournament_id: id, operation_key: 'join')
    end
  end
  ['', ' ', 'x' * 65, 'Ż'].each do |key|
    assert_raises(GameRoomTournaments::Publication::Invalid) do
      GameRoomTournaments::RegistrationProjection.join_values(tournament_id: 1, operation_key: key)
    end
  end
end
