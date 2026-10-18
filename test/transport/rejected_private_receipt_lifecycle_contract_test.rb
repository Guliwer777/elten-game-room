require_relative '../support/private_card_games'
require_relative '../../games/rummy'
require_relative '../../games/ninety_nine'

def receipt_lifecycle_rejoin(h, runners, actor)
  replacement = (h.users - [actor]).last
  native_owner = h.users.find { |user| h.view(user).owner? }
  if native_owner != replacement
    h.view(native_owner).transfer_ownership(h.view(native_owner).participants.find { |p| p.user == replacement })
  end
  h.repositories[replacement].snapshot_for(h.session)
  expected = h.replay(actor).state[:hands][actor].dup
  runners.fetch(actor).close
  h.view(actor).leave
  h.add_client(actor)
  assert(h.join(actor), 'Cold native account did not return')
  runners[actor] = runner_for(h, actor)
  h.instance_variable_set(:@session, h.repositories[actor].snapshot_for(h.session).session)
  assert(h.replay(actor).state[:hands][actor] == expected, 'Rejected disclosure changed the returning hand')
  # A replacement runner first activates/reconciles its execution group,
  # just as the normal screen does before presenting a usable turn.
  2.times { PrivateCardGamesTest.tick(h, runners) }
end

def receipt_lifecycle_write(h, actor, commands)
  # The direct protocol probe does not run GameScreen/Runner's refresh. Bind
  # its write to this account's current native controller projection.
  h.instance_variable_set(:@session, h.repositories[actor].snapshot_for(h.session).session)
  h.write(actor, commands)
end

[GameRoomGames::Rummy.new, GameRoomGames::NinetyNine.new].each do |game|
  h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol],
    options: {'thinking_time' => game.id == 'ninety_nine' ? 600 : 0})
  begin
    actor = h.replay('Alice').current_player
    other = (h.users - [actor]).first
    original = h.replay(actor)
    if game.id == 'rummy'
      card = original.state[:hands][actor].first
      receipt = GameRoomPrivateCardLedger.locate(original.state, actor, card)
      commands = [GameRoomPrivateCards.command('private_show', 'action', operation: 'reveal', **receipt)]
    else
      selection = game.legal_actions(original, actor).first
      card = selection.fetch('card').split('|').first
      receipt = GameRoomPrivateCardLedger.locate(original.state, actor, card)
      status, plan = game.action_for(selection, original, actor,
        context: GameRoomGames::ActionContext.new(now: original.state[:turn_started], server_random: true))
      assert(status == :ok, 'Could not prepare the timed private action')
      commands = plan.events
      h.submit('Alice', {'kind' => 'command', 'action' => 'turn_timeout'},
        context: GameRoomGames::ActionContext.new(now: original.state[:turn_deadline]))
    end
    before = h.replay(actor)
    accepted_ids = before.accepted_events.map { |event| event['id'] }
    before_history = before.history.map(&:to_h)
    receipt_lifecycle_write(h, actor, commands)
    h.broker.deliver(duplicate: true)
    after = h.replay(actor)
    assert(after.accepted_events.map { |event| event['id'] } == accepted_ids, "#{game.id}: rejected action became accepted")
    assert(after.history.map(&:to_h) == before_history, "#{game.id}: rejected action created gameplay history")
    assert(after.state[:hands][actor] == before.state[:hands][actor], "#{game.id}: rejected action consumed a card")
    assert(h.users.all? { |user| GameRoomPrivateCardLedger.known?(h.replay(user).state, receipt) },
      "#{game.id}: authentic irreversible proof did not converge")
    assert(!after.state[:private_public].include?(card), 'Proof knowledge was confused with an accepted card use')

    receipt_lifecycle_rejoin(h, runners, actor)
    assert(h.users.all? { |user| GameRoomPrivateCardLedger.known?(h.replay(user).state, receipt) },
      "#{game.id}: cold return/host transfer lost rejected public evidence")
    assert(h.replay(actor).accepted_events.map { |event| event['id'] } == accepted_ids,
      "#{game.id}: recovery accepted the originally rejected card action")

    if game.id == 'rummy'
      PrivateCardGamesTest.submit(h, runners, actor, {'kind' => 'command', 'action' => 'draw'})
      PrivateCardGamesTest.tick(h, runners)
      PrivateCardGamesTest.submit(h, runners, actor, {'kind' => 'card', 'action' => 'discard', 'card' => card})
      current = h.replay(actor)
      pending = current.state.fetch(:private_disclosure)
      known = GameRoomPrivateCardDisclosure.command(current.state, actor)
      assert(known.pool_request == {'operation' => 'claim'}, 'Recovered proof requested another native reveal')
      bad_value = (1..current.state[:private_pools][receipt[:pool_id]][:cards].size).find { |value| value != receipt[:value] }
      invalid = GameRoomPrivateCards.command('private_show',
        JSON.generate([pending[:purpose], receipt[:draw_id], [bad_value]]), operation: 'claim')
      stable = current.state
      receipt_lifecycle_write(h, actor, [invalid])
      assert(h.replay(actor).state == stable, 'An unproved claimed value changed the pending hand')
      receipt_lifecycle_write(h, other, [known])
      assert(h.replay(actor).state == stable, 'Another account stole the normalized known receipt')
      calls = h.view(actor).calls[:reveal]
      PrivateCardGamesTest.tick(h, runners)
      final = h.replay(actor)
      assert(final.state[:discard].last == card && final.current_player != actor,
        'Normalized known receipt did not finish the valid discard')
      assert(h.view(actor).calls[:reveal] == calls, 'Rejoined account performed a second native reveal')
      PrivateCardGamesTest.assert_private(h)
    else
      # Each accepted timeout keeps its authenticated clock/owner. Returning
      # the active seat to its next turn must not reuse the stale old clock.
      2.times do
        current = h.replay(actor)
        owner = h.users.find { |user| h.view(user).owner? }
        snapshot = h.repositories[owner].snapshot_for(h.session)
        h.instance_variable_set(:@session, snapshot.session)
        # Existing moderator actions keep the original first-seat actor;
        # the authenticated current owner supplies controller authority.
        moderator = current.players.first
        status, timeout = game.action_for({'kind' => 'command', 'action' => 'turn_timeout'},
          current, moderator, context: GameRoomGames::ActionContext.new(now: current.state[:turn_deadline]))
        assert(status == :ok, 'Valid new-host timeout did not prepare')
        h.as(owner) do
          h.repositories[owner].append_events(session: snapshot.session,
            sequence: h.repositories[owner].next_sequence(snapshot.session, snapshot.events),
            events: timeout.events, actor: moderator, controller: owner != moderator)
        end
      end
      current = h.replay(actor)
      assert(current.current_player == actor, 'Three-seat timeout fixture did not return to the actor')
      status, plan = game.action_for(selection, current, actor,
        context: GameRoomGames::ActionContext.new(now: current.state[:turn_started], server_random: true))
      assert(status == :ok && plan.events.first.pool_request == {'operation' => 'claim'},
        'A later valid clock did not reuse the recovered proof')
      calls = h.view(actor).calls[:reveal]
      receipt_lifecycle_write(h, actor, plan.events)
      assert(h.view(actor).calls[:reveal] == calls && !h.replay(actor).state[:hands][actor].include?(card),
        'Recovered receipt was duplicated or not consumed on a valid turn')
    end
  ensure
    runners&.each_value(&:close)
  end
end

puts 'PASS independent rejected native receipts: unchanged history/cards, duplicate delivery, cold return, new owner, fake/foreign claims and valid continuation without re-reveal'
