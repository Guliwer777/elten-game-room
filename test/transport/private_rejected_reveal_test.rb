require_relative '../support/mille_private'
require_relative '../support/private_card_games'
require_relative '../../games/uno'

# Native disclosure survives rule rejection. A later legal use must reuse
# that proof, not ask the server to publish an already revealed value.
h, runners = MillePrivateTest.create
card = h.replay('Bob').state[:hands]['Bob'].first
receipt = GameRoomPrivateCardLedger.locate(h.replay('Bob').state, 'Bob', card)
h.write('Bob', [GameRoomPrivateCards.command('discard', card, operation:'reveal', **receipt)])
assert(h.replay('Bob').state[:hands]['Bob'].include?(card), 'invalid discard consumed card')
assert(h.replay('Alice').state[:discard].empty?, 'invalid discard changed table')
assert(GameRoomPrivateCardLedger.known?(h.replay('Bob').state, receipt), 'rejected native evidence lost')
%w[Alice Bob].each do |actor|
  PrivateCardGamesTest.submit(h, runners, actor, {'kind'=>'command','action'=>'draw'})
  selection = h.game.legal_actions(h.replay(actor), actor).find do |a|
    a['action'] == 'discard' && (actor == 'Alice' || a['card'] == card)
  end
  before = h.view(actor).calls[:reveal]
  PrivateCardGamesTest.submit(h, runners, actor, selection)
  assert(h.view(actor).calls[:reveal] == before, 'repeated native reveal') if actor == 'Bob'
end
assert(h.replay('Alice').state[:discard].include?(card), 'previously rejected card cannot be used')
MillePrivateTest.assert_private(h)
runners.each_value(&:close)

# An interception can arrive while another action awaits a private draw.
# Its native evidence must remain usable for later batched scoring too.
h, runners = PrivateCardGamesTest.create(GameRoomGames::Uno.new, users:%w[Alice Bob Carol])
40.times { PrivateCardGamesTest.tick(h, runners) }
rep = h.replay('Alice')
actor = rep.current_player
other = (h.users - [actor]).first
_, plan = h.game.action_for({'kind'=>'command','action'=>'draw'}, h.replay(actor), actor,
  context:runners[actor].send(:context))
assert(plan, 'no draw to interrupt')
h.write(actor, plan.events)
assert(h.replay(other).state[:phase] == :private_draw, 'not waiting for draw')
card = h.replay(other).state[:hands][other].first
receipt = GameRoomPrivateCardLedger.locate(h.replay(other).state, other, card)
h.write(other, [GameRoomPrivateCards.command('play', "#{card}||0", operation:'reveal', **receipt)])
state = h.replay(other).state
assert(state[:phase] == :private_draw && GameRoomPrivateCardLedger.known?(state, receipt), 'late reveal lost in pending effect')
GameRoomPrivateCardDisclosure.prepare(state, [other], purpose:'test-score', cards:{other=>[card]})
command = GameRoomPrivateCardDisclosure.command(state, other)
assert(command.pool_request == {'operation'=>'claim'}, 'known disclosure repeats native write')
event = {'action'=>'private_show', 'value'=>command.value}
assert(!GameRoomPrivateCardDisclosure.apply(state, event, actor), 'foreign known proof accepted')
assert(GameRoomPrivateCardDisclosure.apply(state, event, other), 'known own proof rejected')
assert(GameRoomPrivateCardDisclosure.complete?(state), 'known packet not completed')
assert(!GameRoomPrivateCardDisclosure.apply(state, event, other), 'known proof spent twice')
runners.each_value(&:close)
puts 'PASS rejected reveals: rule rollback, later legal use, pending effect, scoring, ownership and single use'
