require_relative '../support/private_card_games'
require_relative '../../games/makao'
require_relative '../../lib/game_sounds'

game = GameRoomGames::Makao.new
h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob Carol], random_values:Array.new(16, 8))
actor = h.replay('Alice').current_player
before = h.replay(actor)
PrivateCardGamesTest.submit(h, runners, actor, {'kind'=>'command', 'action'=>'draw'})
pending = h.replay(actor)
assert(pending.state[:phase] == :private_draw, 'draw continuation not requested')
assert(pending.state[:hands] == before.state[:hands], 'partial draw changed hand')
selection = game.automatic_action(pending, actor)
_, plan = game.action_for(selection, pending, actor)
h.broker.automatic_delivery = false
h.view(actor).fail_next_push = :after
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write(actor, plan.events) }
remaining = h.view(actor).pools.first.state['remaining']
h.transports[actor].reconcile(h.table['__id'])
h.broker.automatic_delivery = true
h.broker.deliver(duplicate:true)
assert(h.view(actor).pools.first.state['remaining'] == remaining, 'lost acknowledgement consumed another card')
pending = h.replay(actor)
assert(pending.state[:phase] == :private_effect, 'drawn-card decision not waiting')
assert(pending.history == before.history, 'draw announced before completion')
old_owner = h.view('Alice')
old_owner.transfer_ownership(old_owner.participants.find { |entry| entry.user == 'Carol' })
runners[actor].close
h.view(actor).leave
h.add_client(actor)
assert(h.join(actor), 'account return failed while decision pending')
runners[actor] = runner_for(h, actor)
returned = h.replay(actor)
assert(returned.state[:private_effect] == pending.state[:private_effect], 'pending decision lost on cold return')
assert(returned.state[:phase] == :private_effect, 'pending move committed on return')
selection = game.automatic_action(returned, actor)
_, plan = game.action_for(selection, returned, actor)
other = (h.users - [actor]).first
repo = h.repositories[actor]
event = {'action'=>'private_fact', 'value'=>plan.events.first.value, 'actor'=>other, 'id'=>999}
candidate = GameRoomSnapshot.copy(returned.state)
assert(!game.send(:apply_replay_event, candidate, event, h.session, repo, []), 'foreign fact accepted')
event['actor'] = actor
event['value'] = 'old|' + event['value'].split('|', 2).last
assert(!game.send(:apply_replay_event, candidate, event, h.session, repo, []), 'another move fact accepted')
PrivateCardGamesTest.tick(h, runners)
final = h.replay(actor)
assert(final.state[:phase] == :playing, 'draw never completed')
assert(final.state[:hands][actor].size == before.state[:hands][actor].size + 1, 'wrong completed draw count')
event = final.accepted_events.last
messages = final.history.select { |entry| entry.event_id == repo.event_id(event) }
assert(messages.one? && messages.first.kind == :draw, 'draw announcement not attached to final receipt')
assert(game.describe_event(event, repo, final, actor) == messages.map(&:text), 'normal speech path misses deferred draw')
assert(GameRoomSounds.event_cue(game:game, event:event, before_replay:pending,
  after_replay:final, repository:repo, viewer:actor) == 'draw', 'normal audio path misses deferred draw')
PrivateCardGamesTest.assert_private(h)
runners.each_value(&:close)
puts 'PASS shared private effects: uncertain draw, duplicate delivery, pending cold return/host transfer, fact identity, deferred speech/audio'
