require_relative '../support/mille_private'

options = GameRoomGames::MilleBornes::DECK_COUNTS.keys.to_h do |type|
  ["#{type}_cards", type == '25' ? 13 : (type == 'go' ? 1 : 0)]
end.merge('custom_deck' => true, 'include_safeties' => false, 'recycle_discard' => true)
h, runners = MillePrivateTest.create(options: options)
70.times do
  h.users.each do |user|
    4.times { MillePrivateTest.tick(h, runners) }
    next unless h.replay(user).state[:current_player] == user
    MillePrivateTest.move(h, runners, user, 'draw')
    MillePrivateTest.move(h, runners, user, 'discard')
  end
end
MillePrivateTest.assert_private(h)
replay = h.replay('Alice')
state = replay.state
assert(state[:recycle_count] > 32, 'test did not exceed the lifetime pool limit')
assert(h.view('Alice').pools.length <= 12, 'obsolete native pools accumulated')
assert(state[:private_retired].length > 32, 'retired identities were not recorded')

# A genuinely full set of pools with cards still held must stop explicitly,
# without deleting anyone's hand or repeatedly requesting an impossible pool.
state[:phase] = :awaiting_draw
state[:draw_pile] = []
state[:discard] = ['25:1']
state[:private_retired] = []
state[:private_pools] = (1..32).to_h { |i| [i.to_s.rjust(32, '0'), {cards: ['25:1'], remaining: 0}] }
state[:private_draws] = state[:private_pools].keys.to_h { |id| [id, {pool: id, count: 1, used: []}] }
history = []
h.game.send(:finish_private_replay, state, history, 100)
assert(state[:private_error] == :pool_limit, 'pool limit did not stop the game')
assert(history.one? && history.first.kind == :private_error, 'pool limit was not announced')
assert(h.game.automatic_action(replay, 'Alice', context: runners['Alice'].send(:context)).nil?, 'capacity error keeps sending requests')
runners.each_value(&:close)
puts 'PASS private retirement: more than 32 recyclings; held cards retained; real capacity limit announced'
