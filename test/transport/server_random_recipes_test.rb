require_relative '../support/session_runner'
require_relative '../../games/cat_head_tail'
require_relative '../../games/monopoly'
require_relative '../../games/audio_ball'
require_relative '../../games/war'
require_relative '../../games/biblios'

class NoClientRandom
  def roll(**); raise 'A live server-random action used client entropy'; end
end

[
  [GameRoomGames::CatHeadTail.new, 'roll', 'cat_tail'],
  [GameRoomGames::Monopoly.new, 'roll', 'monopoly_roll'],
  [GameRoomGames::AudioBall.new, 'audio_ball_start', 'first_server'],
  [GameRoomGames::War.new, 'deal', 'seed_text'],
  [GameRoomGames::Biblios.new, 'start', 'seed_text']
].each do |game, action, recipe|
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  h.start
  ctx = GameRoomGames::ActionContext.new(random_source: NoClientRandom.new, server_random: true,
    table_owner: 'Alice', now: 1000)
  h.view('Alice').next_random_values = (1..16).to_a
  h.submit('Alice', {'kind'=>'command', 'action'=>action}, context: ctx)
  h.assert_converged(game.id, expected_count: 1)
  assert(h.replay('Alice').accepted_events.size == 1, "#{game.id}: native draw rejected")
  assert(h.view('Alice').calls[:random] == 1, "#{game.id}: more than one request")
  assert(h.events('Alice').first.dig('__server_random', 'recipe', 'kind') == recipe, 'wrong recipe')
  # Native provenance alone is insufficient: the shape must be the game's
  # actual draw, not an attacker-selected constant or differently sized die.
  other = NativeRoomHarness.new(game: game, users: %w[Alice Bob])
  other.start
  other.view('Alice').next_random_values = [1]
  other.write('Alice', [GameRoomServerRandom.command(action: action, count: 1, sides: 2)])
  assert(other.replay('Alice').accepted_events.empty?, "#{game.id}: wrong draw accepted")
  # The canonical legacy event still yields the same game, preserving saves.
  original = h.events('Alice').first
  legacy = original.reject { |key, _| key == '__server_random' }
  old = game.replay(h.session, [legacy], h.repositories['Alice'])
  assert(GameRoomTest::ReplaySnapshot.capture(old).reject { |key, _| key == :accepted_events } ==
    GameRoomTest::ReplaySnapshot.capture(h.replay('Alice')).reject { |key, _| key == :accepted_events },
    "#{game.id}: legacy replay changed")
end

request = GameRoomServerRandom.text_seed_command(action: 'deal', template: '2|{dealer}|{seed}', seats: [1, 3]).random_request
assert(GameRoomServerRandom.valid_request?(request), 'seed template rejected')
assert(GameRoomServerRandomRendering.render(request['recipe'], Array.new(16, 1)) == '2|1|' + '0' * 32, 'seed wire changed')
['{seed}|{seed}', 'x' * 64 + '{seed}', '{unknown}'].each do |bad|
  malformed = Marshal.load(Marshal.dump(request))
  malformed['recipe']['template'] = bad
  assert(!GameRoomServerRandom.valid_request?(malformed), "unsafe template #{bad}")
end
puts 'PASS server wire recipes: five games, one request, no local entropy, provenance and legacy replay'
