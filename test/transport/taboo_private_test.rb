require_relative '../support/private_card_games'
require_relative '../support/native_private_messages'
require_relative '../support/elten_array_shuffle'
require_relative '../../games/taboo'

game = GameRoomGames::Taboo.new
h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol Dave])
tick = -> { 5.times { PrivateCardGamesTest.tick(h, runners) } }
play = lambda do |user, action, extra = {}, now = nil|
  h.instance_variable_set(:@session, h.repositories[user].snapshot_for(h.session).session)
  replay = h.replay(user)
  ctx = GameRoomGames::ActionContext.new(table_owner: h.core.owner, now: now || [Time.now.to_i, replay.state[:time]].max,
    random_source: GameRoomRandom::LocalSecureSource.new)
  h.submit(user, {'action'=>action, 'token'=>game.token(replay.state)}.merge(extra), context: ctx)
end
assert(h.replay('Alice').state[:phase] == :ready, 'private Taboo did not prepare')
3.times do |turn|
  giver = h.replay('Alice').current_player
  play.call(giver, 'start')
  play.call(h.core.owner, 'begin', {}, h.replay('Alice').state[:deadline])
  tick.call
  mine = h.replay(giver)
  assert(game.card_lines(mine.state, giver).size == 6, 'describer has no card')
  card = mine.state[:taboo_slots].fetch(mine.state[:card])
  guesses = mine.state[:teams][mine.state[:team]] - [giver]
  h.users.each do |user|
    state = h.replay(user).state
    lines = game.card_lines(state, user)
    assert(lines.empty? == guesses.include?(user), "incorrect audience: #{user}")
    if guesses.include?(user)
      assert(!state[:private_values].key?(card[:draw]) && !state[:taboo_shared].key?(card[:draw]), 'secret in guesser snapshot')
      begin
        h.view(user).pool(card[:pool]).draw(card[:draw])
        raise 'server allowed a foreign private draw'
      rescue EltenLink::Error
      end
    end
  end
  # A forged request does not expand the audience, even for the host.
  attacker = guesses.first
  if turn == 0
    # The guessing host is still not a recipient. A cold return must reload
    # both account-owned and selectively delivered values, without a new draw.
    h.view(h.core.owner).transfer_ownership(h.view(h.core.owner).participants.find { |p| p.user == attacker })
    [giver, (h.users - guesses - [giver]).first].each do |returning|
      expected = game.card_lines(h.replay(returning).state, returning)
      runners[returning].close
      h.view(returning).leave
      h.add_client(returning)
      assert(h.join(returning), 'cold return failed')
      runners[returning] = runner_for(h, returning)
      tick.call
      assert(game.card_lines(h.replay(returning).state, returning) == expected, 'cold return lost phrase')
    end
    assert(game.card_lines(h.replay(attacker).state, attacker).empty?, 'guessing host sees phrase')
  end
  h.view(attacker).send_private(giver, {'type'=>'game_room_private', 'version'=>1, 'session_id'=>h.session['__id'],
    'payload'=>{'type'=>'private_draw_share', 'action'=>'request', 'draw'=>card[:draw], 'pool'=>card[:pool]}}, message_id:'attack')
  tick.call
  assert(!h.replay(attacker).state[:taboo_shared].key?(card[:draw]), 'requester granted itself access')
  assert(game.save_game_error(mine), 'private tournament incorrectly saveable')
  play.call(giver, 'correct')
  tick.call
  play.call(h.core.owner, 'timeout', {}, h.replay(giver).state[:deadline])
  tick.call
  assert(h.replay(giver).state[:phase] == :review, 'timeout lost review')
  h.users.each { |user| assert(game.surface_spec(h.replay(user), user).is_a?(GameSurfaces::TabooSpec), 'unrevealed review') }
  play.call(h.core.owner, 'approve')
  tick.call
  assert(h.replay(giver).state[:completed] == turn + 1, 'review not approved')
end
# Expiry before the first private take must not create a fictitious review
# card. If the already prepared take arrives late, reveal it before approval.
giver = h.replay('Alice').current_player
play.call(giver, 'start')
play.call(h.core.owner, 'begin', {}, h.replay(giver).state[:deadline])
rep = h.replay(giver)
ctx = GameRoomGames::ActionContext.new(table_owner:h.core.owner)
_, pending = game.action_for(game.automatic_action(rep, giver, context:ctx), rep, giver, context:ctx)
play.call(h.core.owner, 'timeout', {}, rep.state[:deadline])
assert(h.replay(giver).state[:review].empty?, 'invented undrawn review card')
h.write(giver, pending.events)
assert(!game.send(:private_review_ready?, h.replay(giver).state), 'late draw was not audited')
tick.call
assert(game.send(:private_review_ready?, h.replay(giver).state), 'late draw stayed hidden')
play.call(h.core.owner, 'approve')
runners.each_value(&:close)
puts 'PASS private Taboo: three turns, secret isolation, forged request, guessing host, cold returns, late draw, reveal and scoring'
