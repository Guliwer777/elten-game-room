require_relative '../support/mille_private'
require_relative '../../games/spades'

marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'spades-private'},
  'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1}
h = NativeRoomHarness.new(game: GameRoomGames::Spades.new, users: %w[Alice Bob Carol], tournament: marker,
  options: GameRoomGames::Spades.new.default_options.merge('score_limit'=>100, 'bot_delay'=>0))
h.start
runners = h.users.to_h { |user| [user, runner_for(h, user)] }
16.times { MillePrivateTest.tick(h, runners) }
assert(h.replay('Alice').state[:phase] == :bidding, "opening stalled: #{h.replay('Alice').state[:phase]}")
MillePrivateTest.assert_private(h)
assert(h.events('Alice').count { |e| e['__server_random'] } == 1, 'dealer not server random')
original_hands = h.users.to_h { |user| [user, h.replay(user).state[:hands][user].dup] }
55.times do
  replay = h.replay('Alice')
  break if [:round_complete, :finished].include?(replay.state[:phase])
  user = replay.current_player
  assert(user, "No current player: #{replay.state[:phase]}")
  mine = h.replay(user)
  choice = h.game.legal_actions(mine, user).first
  h.as(user) do
    result = runners[user].submit(session: h.repositories[user].snapshot_for(h.session).session,
      replay: mine, selection: choice, actor: user)
    assert(result.first == :ok, "move rejected: #{result.first}")
  end
  # No automatic new round yet: inspect the just-completed hand first.
  MillePrivateTest.assert_private(h)
end
state = h.replay('Alice').state
assert([:round_complete, :finished].include?(state[:phase]) && !state[:private_error], "round failed #{state[:phase]} #{state[:private_error]}")
assert(h.events('Alice').size == h.replay('Alice').accepted_events.size, 'rejected public event')
assert(h.users.map { |user| h.replay(user).state[:scores] }.uniq.size == 1, 'scoring diverged')
assert(original_hands.values.flatten.uniq.size == 51, 'deal repeated cards')
runners.each_value(&:close)
puts 'PASS Spades private hands: three accounts, public dealer, complete round and same rules audit'
