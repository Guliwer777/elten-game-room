require_relative "../../support/background_help_game_screen"
require_relative "../../../games/three_five_eight"

module ThreeFiveEightTurnSoundTest
  module_function

  def submit(room, replay, selection)
    actor = replay.current_player || replay.players.first
    repository = room.repositories.fetch('Alice')
    snapshot = repository.snapshot_for(room.session)
    context = GameRoomGames::ActionContext.new(server_random: snapshot.session['__server_random'] == GameRoomServerRandom::VERSION)
    status, plan = room.game.action_for(selection, replay, actor, context: context)
    assert(status == :ok, "normal selection rejected: #{status}")
    room.as('Alice') do
      room.view('Alice').next_random_values = [1] * 15 + [selection.fetch('round') * 3 + 2] if selection['action'] == 'deal'
      repository.append_events(session: snapshot.session,
        sequence: repository.next_sequence(snapshot.session, snapshot.events),
        events: plan.events, actor: actor, controller: true)
    end
    result = room.replay('Alice')
    assert(result.accepted_events.length == replay.accepted_events.length + plan.events.length,
      'normal sound fixture lost an event')
    result
  end

  def selection(game, replay)
    state = replay.state
    if [:awaiting_deal, :round_complete].include?(state[:phase])
      round = state[:round] + 1
      # The second deal belongs to Alice, so its start must receive exactly
      # the common own-turn cue when enabled, and no ding when disabled.
      dealer = state[:dealer_index] ? (state[:dealer_index] + 1) % 3 : 1
      {'action' => 'deal', 'round' => round, 'dealer' => dealer, 'seed' => round.to_s(16).rjust(32, '0')}
    else
      game.legal_actions(replay, replay.current_player).first
    end
  end

  def check_presentation(enabled:, covered:)
    game = GameRoomGames::ThreeFiveEight.new
    room, screen = screen_fixture(game, bots: 2)
    sounds = []
    program = screen.instance_variable_get(:@program)
    program.define_singleton_method(:play_sound_from_asset) { |name, **_options| sounds << name; nil }
    screen.instance_variable_set(:@runner_covered, -> { covered })
    screen.define_singleton_method(:speak) { |_message, **_options| }
    replay = room.replay('Alice')
    screen.send(:process_new_events, replay)
    sounds.clear
    saw_next_deal = false
    120.times do
      before = replay
      action = selection(game, before)
      replay = submit(room, before, action)
      sounds.clear
      screen.send(:process_new_events, replay)
      own_key = game.required_decision_key(replay, 'Alice')
      expected = enabled && covered && own_key && own_key != game.required_decision_key(before, 'Alice') ? 1 : 0
      assert(sounds.count('ding') == expected,
        "#{action['action']} round #{replay.state[:round]}: enabled=#{enabled}, covered=#{covered}, expected #{expected} turn ding, got #{sounds.inspect}")
      if action['action'] == 'deal'
        assert(sounds.include?('shuffle'), 'disabling turn cues muted the deal shuffle')
        if replay.state[:round] == 2
          assert(replay.current_player == 'Alice', 'next-deal fixture did not give Alice the contract choice')
          saw_next_deal = true
        end
      end
      previous = sounds.dup
      screen.send(:process_new_events, replay)
      assert(sounds == previous, 'refresh repeated an event or turn cue')
      break if saw_next_deal && action['action'] == 'choose_contract'
    end
    assert(saw_next_deal && replay.state[:round] == 2, 'never reached the next normal deal')
  ensure
    screen&.send(:stop_session_runner)
  end
end

$game_room_test_user = 'Alice'
$activecontrols = []
settings = {'background_table_speech' => false, 'background_turn_sound' => false}
ProgramDouble.define_singleton_method(:normalized_settings) { settings }
failures = []
checks = 0
begin
  [false, true].product([false, true]).each do |enabled, covered|
    settings['background_turn_sound'] = enabled
    begin
      ThreeFiveEightTurnSoundTest.check_presentation(enabled: enabled, covered: covered)
    rescue StandardError => error
      failures << error.message
    end
    checks += 1
  end
  # Zero points are not a new required decision. Check this independent cue
  # branch explicitly without changing the score of the legal game above.
  game = GameRoomGames::ThreeFiveEight.new
  after = GameRoomGames::Replay.new(state: {contract: 'H'})
  [-1, 0, 1].each do |delta|
    entry = GameRoomGames::HistoryEntry.new(kind: :round_result, actor: 'Alice', value: delta)
    cues = game.event_sound_cues(event: {'action' => 'play', 'value' => '2C'}, before_replay: nil,
      after_replay: after, history: [entry], viewer: 'Alice', random_variant: nil)
    expected = ['play'] + (delta > 0 ? ['win1'] : (delta < 0 ? ['lose1'] : []))
    failures << "round delta #{delta}: expected #{expected.inspect}, got #{cues.inspect}" unless cues == expected
    checks += 1
  end
ensure
  ProgramDouble.singleton_class.remove_method(:normalized_settings)
end
puts JSON.pretty_generate(checks: checks, failures: failures)
raise '3-5-8 turn sound regression' unless failures.empty?
puts 'PASS 3-5-8 turn audio: shared setting only, foreground/background, next deal and zero/positive/negative round results'
