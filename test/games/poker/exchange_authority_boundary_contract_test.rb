# Independent review of the exchange parser and idle-status changes.
# Native broker/repository/runner, not live accounts.
require_relative '../../support/clock_event_contract'
require_relative '../../support/private_card_games'
require_relative '../../../games/poker'

def independent_poker_exchange(private_cards)
  game = GameRoomGames::Poker.new
  users = %w[Alice Bob Carol]
  options = {'variant' => 'draw', 'bot_delay' => 0}
  if private_cards
    h, runners = PrivateCardGamesTest.create(game, users: users, options: options)
  else
    h = NativeRoomHarness.new(game: game, users: users, options: game.default_options.merge(options))
    h.start
    runners = users.to_h { |user| [user, runner_for(h, user)] }
    4.times { PrivateCardGamesTest.tick(h, runners) }
  end
  h.add_client('Watcher')
  assert(h.join('Watcher'), 'Observer could not join')
  10.times do
    replay = h.replay('Alice')
    break if replay.state[:phase] == :exchange
    actor = replay.current_player
    selection = game.legal_actions(h.replay(actor), actor).find { |item| %w[check call].include?(item['action']) }
    assert(selection, 'Expected a betting action before exchange')
    PrivateCardGamesTest.submit(h, runners, actor, selection)
    PrivateCardGamesTest.tick(h, runners)
  end
  assert(h.replay('Alice').state[:phase] == :exchange, 'Exchange was not reached')
  [game, h, runners]
end

ClockEventContract.with_server_time do
  [false, true].each do |private_cards|
    game, h, runners = independent_poker_exchange(private_cards)
    begin
      actor = h.replay('Alice').current_player
      mine = h.replay(actor)
      original_hand = mine.state[:hands].fetch(actor).dup
      original_state = Marshal.dump(mine.state)
      original_events = h.events(actor).dup
      malformed = ['["\\uD800"]', "[\"\xFF\"]".b, 'NaN', 'Infinity',
        '[["nested"]]', '[' * 110 + '0' + ']' * 110, "[\"AS\"]\0", '{}']
      malformed.each do |cards|
        selection = {'kind' => 'card_packet', 'action' => 'exchange', 'cards' => cards}
        status, plan = game.action_for(selection, mine, actor)
        assert(status == :invalid_exchange && plan.nil?, "Malformed bytes/nesting accepted: #{cards.inspect}")
        explanation = game.move_error_for(status, selection: selection, replay: mine, actor: actor)
        assert(explanation.is_a?(String) && !explanation.empty?, 'Malformed input lacks a safe explanation')
        assert(original_hand.none? { |card| explanation.include?(card) }, 'Error revealed actual hand identifiers')
        assert(Marshal.dump(mine.state) == original_state && h.events(actor) == original_events,
          'Rejected input changed state or wrote an event')
      end

      # A valid empty packet is still not permission for a different player
      # or a read-only observer to end the active player's exchange.
      (h.users - [actor] + ['Watcher']).each do |outsider|
        selection = {'kind' => 'command', 'action' => 'exchange', 'cards' => '[]'}
        status, plan = game.action_for(selection, h.replay(outsider), outsider)
        assert(status != :ok && plan.nil?, 'Stand-pat bypassed current-player authority')
        status, plan = game.action_for(selection, mine, outsider)
        assert(status != :ok && plan.nil?, 'Using another viewer projection bypassed exchange authority')
      end

      # Escaped but valid IDs and a changed selection order retain the
      # packet's actual meaning, including private positional normalization.
      chosen = original_hand.first(2).reverse
      encoded = '[' + chosen.map { |card| '"' + card.codepoints.map { |cp| '\\u%04x' % cp }.join + '"' }.join(',') + ']'
      PrivateCardGamesTest.submit(h, runners, actor,
        {'kind' => 'card_packet', 'action' => 'exchange', 'cards' => encoded})
      if private_cards
        pending = h.replay('Watcher')
        assert(pending.state[:phase] == :private_draw, 'Private replacement did not use the normal pending phase')
        status_surface = game.surface_spec(pending, 'Watcher')
        assert(status_surface.id == 'private_cards_status' &&
          status_surface.items.first.label == 'Waiting for all players to receive their cards.',
          'Between-hand label replaced an actual pending private draw')
      end
      16.times { PrivateCardGamesTest.tick(h, runners) }
      after = h.replay(actor)
      assert(after.state[:hands][actor].length == 5, 'A valid packet changed the hand size')
      assert((chosen & after.state[:hands][actor]).empty?, 'Chosen cards were not replaced')
      assert((original_hand.drop(2) - after.state[:hands][actor]).empty?, 'An unselected card was replaced')
      event = h.events(actor).reverse.find { |item| item['action'] == 'exchange' }
      payload = GameRoomTurnClock.payload(after.state, event)
      assert(payload == (private_cards ? '1,0' : chosen.join(',')), 'Exchange was encoded with wrong cards/slots')
      PrivateCardGamesTest.assert_private(h) if private_cards
      if private_cards
        spectator = h.replay('Watcher')
        assert(spectator.state[:hands].values.flatten.all? { |card| GameRoomPrivateCardLedger.hidden?(card) },
          'Observer received a private card after exchange')
      end
      status, plan = game.action_for({'kind' => 'card_packet', 'action' => 'exchange', 'cards' => encoded},
        after, actor)
      assert(status != :ok && plan.nil?, 'The completed exchange could execute a second time')
    ensure
      runners.each_value(&:close)
    end
  end
end
puts 'PASS independent Poker parser boundary: malformed bytes/depth, safe errors, actor/viewer authority, escaped IDs, ordered private slots and no repeated exchange'
