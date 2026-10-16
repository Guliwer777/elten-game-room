require_relative '../support/mille_bornes'
include MilleBornesTest
fixture = Fixture.new(players: %w[Alpha Beta], options: {'target_score' => 100})
state = fixture.scenario
state[:hands]['Alpha'] = %w[100:1 50:1]
state[:tracks][0][:miles] = 900
state[:tracks][0][:moving] = true
equal(:ok, fixture.play(state, 'Alpha', 'play', '100:1'), 'Finish new Power Games game')
replay = fixture.snapshot(state)
raise 'New game did not finish' unless replay.finished?
result = fixture.game.tournament_export_result(replay, options: fixture.game.default_options.merge('target_score' => 100))
equal(['Alpha'], result[:winners], 'Generic tournament winner')
scores = fixture.game.tournament_export_scores(replay, options: fixture.game.default_options.merge('target_score' => 100))
equal(fixture.game.participant_scores(replay), scores, 'Game-owned public small points')
puts 'PASS Power Games Mille Bornes: finished winner and public tournament small points'
