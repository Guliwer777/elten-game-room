require_relative '../../support/new_games_fixture'
require_relative '../../../lib/game_sounds'

players = %w[Alice Bob]
repository = NewGames116Repository.new(players)
game = GameRoomGames::Poker.new
session = {'options' => JSON.generate(game.default_options)}
events = []
replay = game.replay(session, events, repository)
cue = lambda do |actor, selection|
  before = replay
  replay = append_action(game, session, repository, events, replay, actor, selection, context_for)
  GameRoomSounds.event_cue(game: game, event: events.last, before_replay: before, after_replay: replay,
    repository: repository, viewer: 'Alice')
end
legal = ->(name) { game.legal_actions(replay, replay.current_player).find { |action| action['action'] == name } }
assert(cue.call('Alice', {'kind' => 'command', 'action' => 'deal'}) == 'shuffle', 'Deal lost shuffle')
assert(cue.call(replay.current_player, legal.call('raise')) == 'poker_raise', 'Raise cue')
assert(cue.call(replay.current_player, legal.call('call')) == 'poker_call', 'Call cue')
assert(cue.call(replay.current_player, legal.call('check')) == 'poker_check', 'Check cue')
assert(cue.call(replay.current_player, legal.call('all_in')) == 'poker_all_in', 'All-in cue')
assert(cue.call(replay.current_player, legal.call('fold')) == %w[poker_fold poker_pot], 'Fold and pot cue')

events.clear
replay = game.replay(session, events, repository)
cue.call('Alice', {'kind' => 'command', 'action' => 'deal'})
cue.call(replay.current_player, legal.call('all_in'))
assert(Array(cue.call(replay.current_player, legal.call('call') || legal.call('all_in'))).first(2) ==
  %w[poker_all_in poker_pot], 'A stack-emptying call did not use the all-in cue')

%w[poker_fold poker_check poker_call poker_raise poker_all_in poker_pot].each do |name|
  assert(GameRoomSounds::ASSET_NAMES.include?(name) && File.file?(File.expand_path("../../../Audio/#{name}.opus", __dir__)),
    "Missing poker asset: #{name}")
end

# Rejected raw actions have no outcome and must not produce success sounds.
%w[deal bet exchange private_draw].each do |action|
  rejected = {'id' => 900, 'actor' => 'Alice', 'action' => action, 'value' => 'exchange'}
  assert(GameRoomSounds.event_cue(game: game, event: rejected, before_replay: replay, after_replay: replay,
    repository: repository, viewer: 'Alice').nil?, "Rejected #{action} emitted a sound")
end

require_relative '../../support/private_card_games'
h, runners = PrivateCardGamesTest.create(game, users: players, options: {'variant' => 'draw', 'thinking_time' => 600})
begin
  2.times do
    rep = h.replay('Alice')
    actor = rep.current_player
    PrivateCardGamesTest.submit(h, runners, actor, game.legal_actions(h.replay(actor), actor).find { |item| item['action'] == 'check' })
  end
  actor = h.replay('Alice').current_player
  rep = h.replay(actor)
  choice = game.legal_actions(rep, actor).find { |item| JSON.parse(item['cards']).size == 2 }
  PrivateCardGamesTest.submit(h, runners, actor, choice)
  pending = h.repositories[actor].snapshot_for(h.session)
  assert(pending.events.last['action'] == 'exchange', 'Fixture did not request a private exchange')
  pending_replay = game.replay(pending.session, pending.events, h.repositories[actor])
  assert(GameRoomSounds.event_cue(game: game, event: pending.events.last, before_replay: rep, after_replay: pending_replay,
    repository: h.repositories[actor], viewer: actor).nil?, 'Private exchange request sounded before cards arrived')
  8.times { PrivateCardGamesTest.tick(h, runners) }
  snapshot = h.repositories[actor].snapshot_for(h.session)
  received = snapshot.events.rindex { |event| event['action'] == 'private_draw' && event['value'] == 'exchange' }
  assert(received, 'Fixture did not receive private replacement cards')
  before = game.replay(snapshot.session, snapshot.events.take(received), h.repositories[actor])
  after = game.replay(snapshot.session, snapshot.events.take(received + 1), h.repositories[actor])
  assert(GameRoomSounds.event_cue(game: game, event: snapshot.events[received], before_replay: before, after_replay: after,
    repository: h.repositories[actor], viewer: actor) == 'draw', 'Accepted private receipt lost the draw cue')
ensure
  runners.each_value(&:close)
end
puts 'PASS Poker accepted audio: raise/call/check/fold/all-in/pot, stack-emptying call, rejected packets and private exchange request versus receipt'
