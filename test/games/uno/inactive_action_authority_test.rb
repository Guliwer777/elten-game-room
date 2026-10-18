require_relative '../../support/new_games_fixture'
require_relative '../../support/native_room_harness'

# Local native broker and production replay, not a live account. Fixed native
# random responses make ordinary deals reproducible; hands, eliminations and
# catch/buzzer windows are reached exclusively through legal game actions.
checks = 0
[:round, :game].each do |elimination|
  game = GameRoomGames::Uno.new
  options = game.default_options.merge('deck' => elimination == :round ? 'no_mercy' : 'classic',
    'no_mercy_limit' => 10, 'score_limit' => elimination == :round ? 5000 : 100,
    'thinking_time' => 0, 'buzzers' => true)
  h = NativeRoomHarness.new(game: game, options: options)
  h.start
  context = GameRoomGames::ActionContext.new(random_source: NewGames116Random.new, now: 1000)
  found = []
  800.times do |index|
    replay = h.replay(h.users.first)
    break if replay.finished? || found.size == 2
    inactive = h.users.find do |player|
      replay.state[elimination == :round ? :round_eliminated : :eliminated][player]
    end
    target = inactive && game.send(:catchable_player, replay.state, inactive)
    action = if inactive && replay.state[:buzzer_active] && !found.include?('buzz')
      'buzz'
    elsif target && !found.include?('catch')
      'catch'
    end
    if action
      assert(game.legal_actions(replay, inactive).empty?, 'Eliminated player has legal actions')
      %w[uno catch buzz].each do |name|
        status, plan = game.action_for({'kind' => 'command', 'action' => name}, replay, inactive, context: context)
        assert(status == :invalid && plan.nil?, "Planning allowed inactive #{name}")
      end
      state_before = Marshal.dump(replay.state)
      history_before = replay.history.map(&:to_h)
      raw_count = h.events(h.users.first).size
      value = action == 'catch' ? "#{target}|0" : '0'
      h.write(inactive, [GameRoomGames::EventCommand.new(action: action, value: value)])
      after = h.replay(h.users.first)
      assert(h.events(h.users.first).size == raw_count + 1,
        'Invalid action never reached the authenticated native record/replay boundary')
      assert(after.accepted_events == replay.accepted_events,
        "Eliminated #{elimination} player #{inactive} was allowed to #{action}")
      assert(Marshal.dump(after.state) == state_before && after.history.map(&:to_h) == history_before,
        "Rejected inactive #{action} mutated state or history")
      active = h.users.find do |player|
        game.legal_actions(after, player).any? { |choice| choice['action'] == action }
      end
      assert(active, 'No active player available for the positive control')
      h.submit(active, {'kind' => 'command', 'action' => action}, context: context, replay: after)
      accepted = h.replay(h.users.first)
      assert(accepted.accepted_events.size == replay.accepted_events.size + 1,
        'Rejected inactive action prevented the next active action')
      if action == 'catch'
        assert(accepted.state[:hands][target].size == 3 && accepted.state[:uno_window].nil?,
          'Active catch no longer applies the normal two-card penalty')
      else
        assert(accepted.state[:buzzer_pressed][active] && !accepted.state[:buzzer_pressed][inactive],
          'Active buzzer was not recorded independently of the rejected press')
      end
      # A cold cache must apply the same authorization, not merely retain the
      # already-built state from the first client's incremental projection.
      h.add_client(h.users.last)
      h.assert_converged("#{elimination}/#{action}")
      found << action
      checks += 1
      replay = accepted
    end
    actor = h.users.first
    selection = game.automatic_action(replay, actor, context: context)
    if selection && selection['action'] == 'deal'
      h.view(actor).next_random_values = Array.new(16, replay.state[:round] + 1)
    end
    unless selection
      actor = replay.state[:buzzer_active] ? game.active_actors(replay).first : replay.current_player
      selection = game.legal_actions(replay, actor, context: context).
        find { |choice| !%w[uno catch].include?(choice['action']) }
    end
    assert(actor && selection, "No legal continuation after #{index} events")
    h.submit(actor, selection, context: context, replay: replay)
  end
  assert(found.sort == %w[buzz catch], "Missing natural #{elimination} elimination windows: #{found.inspect}")
end

puts "PASS UNO: #{checks} native inactive catch/buzzer boundaries, active controls and cold convergence"
