require_relative '../../support/duck_challenge_native'
require_relative '../../support/duck_game_adapter'

include GameRoomTest::Assertions
h = DuckGameAdapterTest::Harness.new(kind: 'copy_number')
driver = DuckChallengeNativeDriver.new
assert_equal(nil, h.game.required_decision_key(nil, 'Alice'), 'Initial decision has no previous replay')
states = [h.replay]
h.start
states << h.replay
h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
states << h.replay
states.each do |replay|
  %w[Alice Bob Spectator].each do |viewer|
    spec = h.game.surface_spec(replay, viewer)
    surface = GameSurfaces.build(spec)
    form = driver.form(surface)
    driver.frame(form, [])
    assert(surface.fields.any?, 'Waiting players and spectators must have a usable native surface')
    if replay.state[:race] && !replay.state[:round] && replay.current_player != viewer
      assert(!surface.fields.any? { |field| field.is_a?(Button) && field.label == 'Roll the die' }, 'Cannot roll out of turn')
    end
  end
end
puts 'PASS Duck race native surfaces: preparation, current/other turn, spectator and initial decision'
