require_relative '../support/clock_event_contract'
require_relative '../../games/four_in_a_row'
require_relative '../../lib/saved_games'
require_relative '../support/card_timeout_restore'

ClockEventContract.with_server_time do |time|
  f = ClockEventContract::Fixture.new(GameRoomGames::FourInARow.new, users: %w[Alice Bob])
  first = f.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => 0, 'y' => 0})
  original = f.snapshot.events
  assert(first == original && first.all? { |event| event['__clock_offset'] == 0 },
    'Immediate ACK and first public replay disagree about the event offset')
  time.call(1002)
  f.freeze('Alice', true)
  time.call(1010)
  f.freeze('Alice', true)
  time.call(1062)
  f.freeze('Alice', false)
  assert(f.snapshot.session['__clock_offset'] == 60, 'A repeated freeze moved the original boundary')
  assert(f.snapshot.events == original, 'A later pause rewrote earlier event timestamps/metadata')
  second = f.submit('Bob', {'kind' => 'grid', 'action' => 'select', 'x' => 1, 'y' => 0})
  assert(second == f.snapshot('Bob').events.last(second.length), 'Post-pause ACK differs from full projection')
  assert(second.all? { |event| event['__clock_offset'] == 60 && event['created_at'] == 1062 },
    'Post-pause event did not retain its own offset and server timestamp')
  time.call(1063)
  f.freeze('Alice', true)
  f.h.as('Alice') { f.h.transports.fetch('Alice').transfer_room_owner(f.h.table, 'Bob') }
  # The usual room read publishes the server-authenticated owner epoch before
  # the successor issues controller operations. A bare native transfer omits
  # this application lifecycle step and is not the UI/runner handover path.
  f.h.as('Bob') { f.h.transports.fetch('Bob').room_snapshot(f.h.table) }
  time.call(1123)
  f.freeze('Bob', false)
  assert(f.logical_now('Bob') == 1003 && f.snapshot('Bob').session['__clock_offset'] == 120,
    "Host succession changed pause duration: now=#{f.logical_now('Bob')}, session=#{f.snapshot('Bob').session.slice('created_at', '__server_started_at', '__clock_offset', '__frozen_at').inspect}")
  assert(f.snapshot('Bob').events.first(original.length) == original, 'Second pause mutated an old event')
  time.call(1124)
  third = f.submit('Alice', {'kind' => 'grid', 'action' => 'select', 'x' => 2, 'y' => 0})
  assert(third.all? { |event| event['__clock_offset'] == 120 && event['created_at'] == 1124 },
    'Second post-pause event used a stale current offset')
  current = f.snapshot('Bob')
  3.times do
    assert(f.snapshot('Alice').events == current.events && f.snapshot('Bob').events == current.events,
      'Cached clients disagree about historical offsets')
  end
  assert(GameRoomSessionClock.from_server(current.session, 1124) == 1004,
    'Current-time translation changed when no event is passed')
  assert(GameRoomSessionClock.from_server(current.session, 1000, event: original.first) == 1000,
    'Historical translation used the current offset')

  # An ordinary archive keeps its existing format and current logical save
  # time. New native events in the resumed room use its initial restore offset.
  f.freeze('Bob', true)
  frozen = f.snapshot('Bob')
  table = f.h.transports.fetch('Bob').room_snapshot(f.h.table)[:table]
  saves = SavedGames.new(TimedArchiveMemory.new, owner: 'Bob')
  row = saves.put(game: f.game, table: table, snapshot: frozen,
    repository: f.h.repositories.fetch('Bob'), now: 1124)
  assert(row['game_time'] == 1004 && row['saved_at'] == 1124, 'Current logical archive time or real save time changed')
  assert(row['events'].none? { |event| event.key?('__clock_offset') }, 'Ordinary archive format changed unexpectedly')
  time.call(4000)
  restored_data = saves.restored_data(row, game: f.game, table_id: 1771, now: 4000)
  assert(restored_data[:clock_offset] == 2996, 'Restored initial offset changed')
  transport = f.h.transports.fetch('Bob')
  restored_table = f.h.as('Bob') do
    transport.create_room(name: 'Ordinary event-clock restore', game: f.game.id,
      owner: 'Bob', game_options: row['options'], capacity: 2)
  end
  alice = f.h.transports.fetch('Alice')
  discovered = alice.discover_rooms.find { |entry| entry['__id'] == restored_table['__id'] }
  f.h.as('Alice') { alice.establish_membership(table_id: restored_table['__id'], owner: 'Bob', capacity: 2, user: 'Alice', table: discovered) }
  repository = f.h.repositories.fetch('Bob')
  restored = f.h.as('Bob') do
    repository.restore_session(table: restored_table, game: f.game.id, players: restored_data[:players],
      options: row['options'], restore: restored_data)
  end
  before = repository.snapshot_for(restored)
  assert(ClockEventContract.clock.now(before.session) == 1004, 'Restored game clock no longer matches the save')
  assert(f.game.replay(before.session, before.events, repository).board == f.replay('Bob').board,
    'Clock projection changed the ordinary restored position')
  added = f.h.as('Bob') do
    repository.append_events(session: before.session, sequence: repository.next_sequence(before.session, before.events),
      events: [GameRoomGames::EventCommand.new(action: 'drop', value: '3')], actor: 'Bob')
  end
  assert(added.all? { |event| event['__clock_offset'] == 2996 && event['created_at'] == 4000 },
    'Restored writer ACK omitted the initial archive offset')
  assert(repository.snapshot_for(restored).events.last(added.length) == added, 'Restored writer ACK differs from replay')
end

puts 'PASS clock-event projection: immutable historical offsets, repeated freezes, multiple pauses, host succession, ACK/cache parity, unchanged current/save timestamps and ordinary archive restore'
