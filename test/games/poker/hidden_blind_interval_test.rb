require_relative '../../support/private_card_games'
require_relative '../../../games/poker'

%w[hands minutes never].each do |interval|
  game = GameRoomGames::Poker.new
  options = game.default_options.merge('variant' => 'draw', 'draw_uses_blinds' => false,
    'blind_interval' => interval, 'blind_interval_value' => 0)
  assert(game.validation_error(options, player_count: 2).nil?, 'Inactive blind settings must retain their existing validation contract')
  definition = game.effective_option_definitions.find { |item| item.key == 'blind_interval_value' }
  assert(!game.option_visible?(definition, options), 'The regression must concern the hidden ante-only option')
  h = NativeRoomHarness.new(game: game, users: %w[Alice Bob], options: options)
  h.start
  h.users.each do |user|
    assert(h.repositories[user].session_for_table(h.table)['__id'] == h.session['__id'], 'The start was not accepted by the native projection')
    assert(!game.custom_game_shortcuts(h.replay(user), user).empty?, 'The initial ante-only surface must remain available')
  end
  context = GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
    now: 1000, random_source: GameRoomRandom::SeededSource.new(6))
  h.submit('Alice', {'kind' => 'command', 'action' => 'deal'}, context: context)
  h.users.each do |user|
    replay = h.replay(user)
    assert(replay.state[:phase] == :betting && replay.accepted_events.size == 1, 'Normal server deal failed with an inactive zero interval')
    assert(replay.state[:contributions].values == [5, 5], 'The fix must not alter ante payments')
    assert(replay.state[:options]['blind_interval_value'] == 0, 'The stored options must not be rewritten')
    cold = GameRoomGames::Poker.new.replay(h.session, h.events(user), h.repositories[user])
    assert(cold.state == replay.state, 'Cold replay changed the same accepted hand')
  end
  h.assert_converged('ante-only zero blind interval', expected_count: 1)
end

# Private tournament dealing uses the same common blind arithmetic before it
# replaces the provisional hands with authenticated, account-owned receipts.
%w[hands minutes].each do |interval|
  game = GameRoomGames::Poker.new
  h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob], options: {
    'variant' => 'draw', 'draw_uses_blinds' => false,
    'blind_interval' => interval, 'blind_interval_value' => 0
  })
  begin
    assert(h.replay('Alice').state[:phase] == :betting, 'Private draw did not finish its initial dealing')
    PrivateCardGamesTest.assert_private(h)
    assert(h.events('Bob').count { |event| event['action'] == 'deal' } == 1, 'The fix generated a second private deal')
    actor = h.replay('Alice').current_player
    choice = game.legal_actions(h.replay(actor), actor).find { |item| item['action'] == 'fold' }
    PrivateCardGamesTest.submit(h, runners, actor, choice)
    assert(h.replay('Bob').state[:phase] == :hand_complete, 'An ordinary accepted action after private dealing no longer works')
  ensure
    runners.each_value(&:close)
  end
end

# Existing meaningful and historical nonzero values retain exactly the old
# arithmetic. Active blind schedules still reject zero in normal setup.
%w[holdem draw].product([true, false], %w[hands minutes never], [-5, -1, 1, 5, 100]).each do |variant, uses_blinds, interval, value|
  game = GameRoomGames::Poker.new
  options = game.default_options.merge('variant' => variant, 'draw_uses_blinds' => uses_blinds,
    'blind_interval' => interval, 'blind_interval_value' => value)
  state = game.send(:initial_state, %w[Alice Bob], options)
  state.merge!(hand_number: 13, hand_started_at: 2400, tournament_started_at: 1000)
  expected = interval == 'never' ? 0 : (interval == 'hands' ? 12 / value : 1400 / (value * 60))
  assert(game.send(:blind_level, state) == expected, "Historical nonzero interval changed: #{options.inspect}")
end
game = GameRoomGames::Poker.new
assert(!game.validation_error(game.default_options.merge('blind_interval_value' => 0), player_count: 2).nil?, 'An active zero interval must remain invalid')
puts 'PASS Poker hidden blind interval: accepted native start/deal/cold replay, initial shortcuts, private receipts and unchanged nonzero history'
