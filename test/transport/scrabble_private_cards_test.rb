require_relative '../support/private_card_games'
require_relative '../../games/scrabble'

game = GameRoomGames::Scrabble.new
h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob Carol],
  options:game.normalize_options('content_language_id'=>'en'), random_values:Array.new(16, 8))
PrivateCardGamesTest.assert_private(h)
initial = h.replay('Alice')
assert(initial.state[:phase] == :playing, "private rack not delivered #{initial.state.inspect}; events #{h.events('Alice').inspect}")
assert(initial.state[:hands].equal?(initial.state[:racks]), 'rack alias lost')
initial_pool = initial.state[:private_pool]
original_bag = initial.state[:bag].size
exchanges = []

4.times do |index|
  actor = h.replay('Alice').current_player
  before = h.replay(actor)
  selected = before.state[:racks][actor].first(3)
  if index.zero?
    # Returning precedes drawing in the existing game. Choose an authenticated
    # seed whose shuffled stock draws from that returned batch immediately.
    byte = (0..255).find do |value|
      stock = Array.new(original_bag, :old) + Array.new(3, :returned)
      GameRoomRandom.shuffle(stock, random:Random.new((value.to_s(16).rjust(2,'0') * 16).to_i(16))).first(3).include?(:returned)
    end
    assert(byte, 'fixture lacks a return-and-redraw seed')
    h.view(actor).next_random_values = Array.new(16, byte + 1)
  end
  PrivateCardGamesTest.submit(h, runners, actor, {'action'=>'exchange', 'tiles'=>selected})
  if index.zero?
    owner = h.view('Alice')
    owner.transfer_ownership(owner.participants.find { |p| p.user == 'Carol' })
  end
  40.times do
    PrivateCardGamesTest.tick(h, runners)
    break if h.replay(actor).state[:phase] == :playing
  end
  PrivateCardGamesTest.assert_private(h)
  after = h.replay(actor)
  assert(after.state[:revision] == before.state[:revision] + 1, "exchange incomplete #{after.state[:private_effect].inspect}")
  assert(after.state[:racks][actor].size == 7, 'exchange changed rack size')
  assert(after.state[:bag].size == original_bag, 'exchange changed bag size')
  assert(h.view(actor).pools.any? { |pool| pool.id == initial_pool }, 'nonempty original stock retired')
  assert(after.accepted_events.size == h.events(actor).size, 'exchange receipt rejected')
  if index.zero?
    assert((selected & after.state[:racks][actor]).any?, 'returned tiles cannot be drawn again immediately')
  end
  exchanges << {actor:actor, returned:selected, received:after.state[:racks][actor].last(3)}
end
assert(exchanges.any? { |entry| entry[:actor] != 'Carol' }, 'non-host exchange not covered')

actor = h.replay('Alice').current_player
before = h.replay(actor)
runners[actor].close
h.view(actor).leave
h.add_client(actor)
assert(h.join(actor), 'cold return failed')
runners[actor] = runner_for(h, actor)
assert(h.replay(actor).state[:racks][actor] == before.state[:racks][actor], 'returned rack changed')
PrivateCardGamesTest.tick(h, runners)
PrivateCardGamesTest.assert_private(h)

# Place a real dictionary word using only this account's rack. The regular
# placement validator, payload, preview and refill all remain in use.
played = false
3.times do
  actor = h.replay('Alice').current_player
  mine = h.replay(actor)
  rack = mine.state[:racks][actor]
  choice = rack.permutation(2).find do |ids|
    word = ids.map { |id| game.tiles(mine.state)[id][:letter] }.join
    word.size == 2 && game.dictionary(mine.state).include?(word)
  end
  if choice
    placements = choice.each_with_index.map { |id,i| [id,112+i,game.tiles(mine.state)[id][:letter]] }
    PrivateCardGamesTest.submit(h, runners, actor, {'action'=>'place', 'placements'=>placements})
    40.times do
      PrivateCardGamesTest.tick(h, runners)
      break if h.replay(actor).state[:phase] == :playing
    end
    final = h.replay(actor)
    assert(final.state[:board].compact.size == 2 && final.state[:racks][actor].size == 7, 'placement/refill failed')
    assert(final.state[:bag].size == original_bag - 2, 'refill stock count wrong')
    played = true
    break
  end
  PrivateCardGamesTest.submit(h, runners, actor, {'action'=>'pass'})
end
assert(played, 'fixture has no playable two-letter word')
PrivateCardGamesTest.assert_private(h)
h.users.each do |user|
  replay = h.replay(user)
  assert(game.surface_spec(replay,user), 'normal surface missing')
  game.game_shortcuts(replay,user)
end
assert(h.replay('Alice').accepted_events.size == h.events('Alice').size, 'valid private events rejected')

# Several stocks can now coexist. A valid receipt from a different pool must
# never satisfy the requested stock, and a nonempty pool cannot be retired.
state = GameRoomSnapshot.copy(h.replay(actor).state)
pool_ids = state[:private_pools].keys
assert(pool_ids.size > 1, 'mixed-pool fixture missing')
event = {'__server_pool'=>{'operation'=>'take', 'pool_id'=>pool_ids.last,
  'count'=>1, 'draw_id'=>'foreign-stock', 'visibility'=>'private',
  'remaining'=>state[:private_pools][pool_ids.last][:remaining] - 1}}
assert(!GameRoomPrivateCardLedger.record_take(state, event, actor, count:1, pool_id:pool_ids.first),
  'receipt from another stock accepted')
state[:private_draws].each_value { |draw| draw[:used] = Array.new(draw[:count], 1) }
assert(!GameRoomPrivateCardLedger.retirable_pools(state).include?(initial_pool), 'nonempty pool retired after all previous draws revealed')
state[:private_pools][initial_pool][:remaining] = 0
assert(GameRoomPrivateCardLedger.retirable_pools(state).include?(initial_pool), 'fully consumed/revealed pool never retired')
runners.each_value(&:close)
puts "PASS private Scrabble: mixed-stock exchanges #{exchanges.inspect}, real word/refill, host transfer, cold return, public-state agreement"
