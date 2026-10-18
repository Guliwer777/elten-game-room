require_relative '../support/session_runner'
require_relative '../support/native_private_pools'
require_relative '../../games/mille_bornes'

marker = {'publication_ref' => {'author' => 'Alice', 'publication_key' => 'private-test'},
  'schedule_id' => 'a' * 64, 'match_id' => 'b' * 64, 'leg' => 1}
h = NativeRoomHarness.new(game: GameRoomGames::MilleBornes.new, users: %w[Alice Bob], tournament: marker)
h.start
assert(h.session['__private_cards'] == 1, 'tournament did not select private hands')
runners = h.users.to_h { |user| [user, runner_for(h, user)] }
8.times { runners.each { |user, runner| step(h, runner, user) } }
h.users.each do |user|
  replay = h.replay(user)
  assert(replay.state[:phase] == :awaiting_draw, "private deal stalled: #{replay.state[:phase]}")
  assert(replay.state[:hands][user].size == 6, 'wrong initial hand size')
  other = (h.users - [user]).first
  assert(replay.state[:hands][other].all? { |card| card.start_with?('hidden:') }, 'foreign cards entered local state')
  assert(replay.state[:hands][user].none? { |card| card.start_with?('hidden:') }, 'own hand unavailable')
end
assert(h.events('Alice') == h.events('Bob'), 'public receipts differ')
h.core.entries.each do |entry|
  next unless entry.dig('pool', 'operation') == 'take'
  assert(!entry['packet'].key?('values'), 'private draw values in public stack')
end
h.as('Alice') do
  a = h.replay('Alice')
  assert(runners['Alice'].submit(session: h.session, replay: a, selection: {'kind' => 'command', 'action' => 'draw'}, actor: 'Alice').first == :ok, 'draw failed')
end
runners.each { |user, runner| step(h, runner, user) }
hand = h.replay('Alice').state[:hands]['Alice']
h.as('Alice') do
  assert(runners['Alice'].submit(session: h.session, replay: h.replay('Alice'),
    selection: {'kind' => 'card', 'action' => 'discard', 'card' => hand.first}, actor: 'Alice').first == :ok, 'discard failed')
end
runners.each { |user, runner| step(h, runner, user) }
assert(h.replay('Bob').state[:discard] == [hand.first], 'revealed discard missing')
assert(h.replay('Bob').state[:hands]['Alice'].size == 6, 'foreign hand size wrong')
assert(h.game.participant_replacement_error(h.replay('Alice'), player: 'Bob'), 'replacement not blocked')
assert(h.game.save_game_error(h.replay('Alice')), 'private save not blocked')
runners.each_value(&:close)
puts 'PASS private Mille Bornes: initial hands, native draw/reveal, public receipts and restrictions'
