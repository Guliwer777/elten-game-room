require_relative '../support/native_room_harness'
require_relative '../../lib/presentation_replay'
require_relative '../../games/four_in_a_row'

game = GameRoomGames::FourInARow.new
room = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
room.start
repository = room.repositories.fetch('Alice')
play = lambda do
  replay = room.replay('Alice')
  room.submit(replay.current_player, game.legal_actions(replay, replay.current_player).first)
end
2.times { play.call }
before_snapshot = repository.snapshot_for(room.session)
before = game.replay(before_snapshot.session, before_snapshot.events, repository)
2.times { play.call }
after_snapshot = repository.snapshot_for(room.session)
after = game.replay(after_snapshot.session, after_snapshot.events, repository)
batch = after.accepted_events.drop(before.accepted_events.length)
changed = (before_snapshot.session.keys | after_snapshot.session.keys).select do |key|
  before_snapshot.session[key] != after_snapshot.session[key]
end
assert(changed == ['__game_revision'], "Fixture changed more than the native CAS revision: #{changed.inspect}")
assert(batch.length == 2, 'Fixture did not accept two real moves')
original = game.method(:replay)
calls = []
game.define_singleton_method(:replay) do |*args|
  calls << args[1].length
  original.call(*args)
end
cache = GameRoomPresentationReplay.new(game, repository)
cache.remember(before_snapshot.session, before)
untouched = Marshal.dump([before_snapshot.session, after_snapshot.session, before, after])
transitions = cache.transitions(after_snapshot.session, after, batch)
assert(calls.empty?, "Changing only write CAS caused full-prefix replay: #{calls.inspect}")
batch.each_with_index do |event, index|
  prefix = before.accepted_events.length + index
  expected = [original.call(after_snapshot.session, after.accepted_events.take(prefix), repository),
    original.call(after_snapshot.session, after.accepted_events.take(prefix + 1), repository)]
  assert(transitions.fetch(repository.event_id(event)).map(&:to_h) == expected.map(&:to_h),
    'Cached transition differs from full replay')
end
assert(Marshal.dump([before_snapshot.session, after_snapshot.session, before, after]) == untouched,
  'Presentation changed session metadata or canonical state')

# Revision is the sole exclusion. Every existing identity/clock/roster/boundary
# field still invalidates the remembered prefix, including unrecognized fields.
changes = {
  '__control_epoch' => 'later-epoch', '__id' => room.session.fetch('__id') + 1,
  '__clock_offset' => 10, '__frozen' => true, '__frozen_at' => 1000,
  '__clock_revision' => 1, '__table_owner' => 'Bob', '__game_boundary' => 'later-boundary',
  '__seat_changes' => [{'id' => 0, 'players' => %w[Alice Bob]}],
  '__tournament_presence' => {'absent' => ['Bob']},
  'options' => JSON.generate(game.default_options.merge('bot_delay' => 2)),
  'future_semantic_metadata' => true
}
changes.each do |key, value|
  session = after_snapshot.session.merge(key => value)
  canonical = original.call(session, after.accepted_events, repository)
  cache = GameRoomPresentationReplay.new(game, repository)
  cache.remember(before_snapshot.session, before)
  calls.clear
  cache.transitions(session, canonical, batch)
  assert(calls == [before.accepted_events.length], "#{key}: semantic change reused a stale cache: #{calls.inspect}")
end

cache = GameRoomPresentationReplay.new(game, repository)
cache.remember(before_snapshot.session, before)
cache.instance_variable_get(:@previous).accepted_events.first['value'] = 'stale'
calls.clear
cache.transitions(after_snapshot.session, after, batch)
assert(calls == [before.accepted_events.length], 'Different accepted prefix reused cache after CAS change')
room.assert_converged('Presentation revision fixture', expected_count: 4)
puts "PASS native action revision: two exact intermediate transitions, immutable metadata, #{changes.size} semantic invalidations and stale-prefix refusal"
