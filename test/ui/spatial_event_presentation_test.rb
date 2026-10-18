require_relative '../support/background_help_game_screen'

original_play = GameRoomSounds.method(:play)
original_engine = GameRoomSpatialSound.method(:engine_ready?)
GameRoomSpatialSound.define_singleton_method(:engine_ready?) { true }
begin
  h, screen = screen_fixture(GameRoomGames::FourInARow.new)
  program = screen.instance_variable_get(:@program)
  hrtf_enabled = true
  program.define_singleton_method(:game_room_hrtf?) { |_id| hrtf_enabled }
  calls = []
  GameRoomSounds.define_singleton_method(:play) do |_program, cue, **options|
    calls << [cue, options]
    nil
  end
  screen.send(:process_new_events, h.replay('Alice'))

  calls.clear
  h.write('Alice', [GameRoomGames::EventCommand.new(action: 'drop', value: '1')])
  screen.send(:process_new_events, h.replay('Alice'))
  assert(!calls.empty? && calls.all? { |_cue, options| options.empty? },
    'Own move no longer uses ordinary centred playback')

  calls.clear
  h.write('Bob', [GameRoomGames::EventCommand.new(action: 'drop', value: '7')])
  screen.send(:process_new_events, h.replay('Alice'))
  expected = GameRoomSpatialSound.position(%w[Alice Bob], 'Alice', 'Bob')
  assert(calls.any? { |_cue, options| options[:spatial] == expected },
    'Remote move did not reach the output with its authenticated actor seat')

  # A strict original output adapter must keep receiving sounds when HRTF is
  # disabled. Unexpected keywords raise here and would be caught by the real
  # presenter, reproducing the swallowed-sound regression from the PR's CI.
  hrtf_enabled = false
  plain = []
  GameRoomSounds.define_singleton_method(:play) { |_program, cue| plain << cue; nil }
  [['Alice', '2'], ['Bob', '6']].each do |actor, column|
    before = plain.length
    h.write(actor, [GameRoomGames::EventCommand.new(action: 'drop', value: column)])
    screen.send(:process_new_events, h.replay('Alice'))
    assert(plain.length > before, 'Disabling HRTF suppressed an ordinary move sound')
  end
ensure
  screen&.send(:stop_session_runner)
  GameRoomSounds.define_singleton_method(:play, original_play)
  GameRoomSpatialSound.define_singleton_method(:engine_ready?, original_engine)
end
puts 'PASS spatial event presentation: own centre, remote actor seat, disabled HRTF preserves ordinary output'
