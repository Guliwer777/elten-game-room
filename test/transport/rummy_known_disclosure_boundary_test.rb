require_relative '../support/private_card_games'
require_relative '../../games/rummy'

h, runners = PrivateCardGamesTest.create(GameRoomGames::Rummy.new,
  users: %w[Alice Bob], options: {'thinking_time'=>0})
begin
  actor = h.replay('Alice').current_player
  other = (h.users - [actor]).first
  state = h.replay(actor).state
  accepted_before = h.replay(actor).accepted_events.map { |event| event['id'] }
  card = state[:hands].fetch(actor).first
  receipt = GameRoomPrivateCardLedger.locate(state, actor, card)
  h.write(actor, [GameRoomPrivateCards.command('private_show', 'action', operation:'reveal', **receipt)])
  before = h.replay(actor)
  assert(before.state[:hands][actor].include?(card), 'Premature disclosure played a card')
  assert(GameRoomPrivateCardLedger.known?(before.state, receipt), 'A rejected native reveal lost its authentic public evidence')
  assert(before.accepted_events.map { |event| event['id'] } == accepted_before,
    'Premature disclosure was accepted as a legal action')
  assert(GameRoomPrivateCardLedger.known?(h.replay(other).state, receipt),
    'Other accounts lost public native evidence')
  assert(h.replay(other).state[:hands][actor].all? { |item| GameRoomPrivateCardLedger.hidden?(item) },
    'Rejected disclosure changed another account\'s hand projection')
  PrivateCardGamesTest.submit(h, runners, actor, {'kind'=>'command','action'=>'draw'})
  PrivateCardGamesTest.tick(h, runners)
  PrivateCardGamesTest.submit(h, runners, actor, {'kind'=>'card','action'=>'discard','card'=>card})
  assert(h.replay(actor).state[:phase] == :private_show, 'A private discard did not request its proof')
  disclosure = GameRoomPrivateCardDisclosure.command(h.replay(actor).state, actor)
  assert(disclosure.pool_request == {'operation'=>'claim'}, 'Known proof requested another native reveal')
  h.write(other, [disclosure])
  assert(h.replay(actor).state[:phase] == :private_show, 'Another account consumed the owner\'s receipt')
  reveals = h.view(actor).calls[:reveal]
  PrivateCardGamesTest.tick(h, runners)
  final = h.replay(actor)
  assert(final.state[:discard].include?(card), 'Known proof did not complete the discard')
  assert(final.current_player != actor, 'Known proof did not end the turn')
  assert(h.view(actor).calls[:reveal] == reveals, 'Known proof was revealed a second time')
  expected = final.state
  h.write(actor, [disclosure])
  assert(h.replay(actor).state == expected, 'Repeated disclosure changed the next turn')
  PrivateCardGamesTest.assert_private(h)
ensure
  runners.each_value(&:close)
end

puts 'PASS Rummy authenticated rejected disclosure, known receipt continuation and other hands remain private'
