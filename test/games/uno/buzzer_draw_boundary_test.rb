require_relative '../../support/new_games_fixture'
require_relative '../../support/private_card_games'

# Reach the window through ordinary authenticated actions. No hand, reducer,
# accepted event or server draw is replaced by this fixture.
[false, true].each do |private_cards|
  game = GameRoomGames::Uno.new
  options = {'buzzers'=>true, 'thinking_time'=>0, 'score_limit'=>5000}
  runners = {}
  if private_cards
    h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob Carol], options:options,
      random_values:Array.new(16, 2))
  else
    h = NativeRoomHarness.new(game:game, options:game.default_options.merge(options))
    h.start
  end
  context = GameRoomGames::ActionContext.new(random_source:NewGames116Random.new, now:1000)
  settle = lambda do
    80.times do
      PrivateCardGamesTest.tick(h, runners)
      break unless game.send(:private_waiting?, h.replay(h.users.first).state)
    end if private_cards
  end
  submit = lambda do |actor, selection|
    if private_cards
      PrivateCardGamesTest.submit(h, runners, actor, selection)
      settle.call
    else
      h.submit(actor, selection, context:context)
    end
  end
  begin
    found = false
    500.times do
      settle.call
      replay = h.replay(h.users.first)
      break if replay.finished?
      if replay.state[:buzzer_active]
        found = true
        break
      end
      actor = h.users.first
      selection = game.automatic_action(replay, actor, context:context) unless private_cards
      if selection && selection['action'] == 'deal'
        h.view(actor).next_random_values = Array.new(16, replay.state[:round]+1)
      else
        actor = replay.current_player
        selection = game.legal_actions(h.replay(actor), actor, context:context).
          find { |choice| !%w[uno catch].include?(choice['action']) }
      end
      assert(actor && selection, 'No legal continuation before the buzzer')
      submit.call(actor, selection)
    end
    assert(found, 'Fixture never reached a natural buzzer')
    before = h.replay(h.users.first)
    actor = before.current_player
    mine = h.replay(actor)
    assert(game.legal_actions(mine, actor).map { |choice| choice['action'] } == ['buzz'], 'Unexpected buzzer actions')
    status, plan = game.action_for({'kind'=>'command', 'action'=>'draw'}, mine, actor, context:context)
    assert(status == :cannot_draw && plan.nil?, 'Planning allowed a draw during the buzzer')
    raw_count = h.events(h.users.first).size
    command = private_cards ? GameRoomPrivateCards.command('draw', '0', operation:'claim') :
      GameRoomGames::EventCommand.new(action:'draw', value:'0')
    h.write(actor, [command])
    after = h.replay(h.users.first)
    assert(h.events(h.users.first).size > raw_count, 'Bad action never reached authenticated replay')
    assert(after.accepted_events == before.accepted_events, 'Draw during the buzzer was accepted')
    assert(Marshal.dump(after.state) == Marshal.dump(before.state), 'Rejected draw changed the state')
    assert(after.history.map(&:to_h) == before.history.map(&:to_h), 'Rejected draw changed history')
    h.add_client(h.users.last)
    if private_cards
      runners[h.users.last].close
      runners[h.users.last] = runner_for(h, h.users.last)
      PrivateCardGamesTest.assert_private(h)
    else
      h.assert_converged('rejected buzzer draw, cold client')
    end
    h.users.each { |user| submit.call(user, {'kind'=>'command', 'action'=>'buzz'}) }
    after = h.replay(h.users.first)
    assert(!after.state[:buzzer_active] && after.state[:phase] == :playing, 'Buzzer did not finish normally')
    actor = after.current_player
    count = after.state[:hands][actor].size
    expected_draws = [after.state[:pending_draw], 1].max
    submit.call(actor, {'kind'=>'command', 'action'=>'draw'})
    assert(h.replay(actor).state[:hands][actor].size == count+expected_draws, 'Normal next draw failed')
    PrivateCardGamesTest.assert_private(h) if private_cards
  ensure
    runners.each_value(&:close)
  end
end

puts 'PASS UNO buzzer draw: ordinary/private authenticated rejection, unchanged state, cold replay, normal buzz and draw'
