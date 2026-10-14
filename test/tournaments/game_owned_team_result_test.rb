require_relative '../support/tournament_individual_execution'
require_relative '../../lib/game_simulation'
include TournamentIndividualExecutionSupport
players = %w[Alpha Beta Gamma Delta]
template = [0, 1, 0, 1]
planned = players.each_with_index.map { |name, seat| {'username' => name, 'account' => name.downcase, 'team' => template[seat].zero? ? 'red' : 'blue'} }
%w[domino taboo].each do |id|
  game = GameRoomGames::CATALOG.build(id)
  options = id == 'domino' ? {'teams' => true, 'team_count' => '2', 'score_limit' => 1} : {'turns_each' => 1, 'turn_seconds' => 30}
  options = game.with_team_assignment(game.normalize_options(options), players: players, seats: template)
  environment = GameRoomSimulation::Environment.new_game(game: game, players: players, options: options, seed: 17)
  if id == 'domino'
    500.times do
      break if environment.finished?
      selection = environment.legal_actions.first
      assert(selection, 'Domino must expose a legal production action')
      assert_equal(:ok, environment.step(selection))
    end
  else
    # Controlled simulation clock; all moderation and scoring still pass
    # through production action_for and accepted, replayable game commands.
    clock = 0
    original_context = environment.method(:context)
    environment.define_singleton_method(:context) do
      value = original_context.call
      value.now = clock
      value
    end
    60.times do
      break if environment.finished?
      state = environment.replay.state
      actor = players.first
      action = case state[:phase]
      when :ready then actor = state[:current_player]; 'start'
      when :preparing then clock = state[:deadline]; 'begin'
      when :describing
        if state[:team].zero? && state[:review].empty?
          actor = state[:current_player]; clock += 1; 'correct'
        else
          clock = state[:deadline]; 'timeout'
        end
      when :review then 'approve'
      else raise "Unexpected Taboo phase #{state[:phase]}"
      end
      assert_equal(:ok, environment.step({'action' => action, 'token' => game.token(state)}, actor: actor))
    end
  end
  replay = environment.replay
  assert(replay.finished?, "#{id} production rules did not finish")
  assert_equal(environment.events.size, replay.accepted_events.size)
  if id == 'domino'
    assert_raises(GameRoomGames::Base::Tournaments::InvalidResult) do
      T::GameResult.from_replay(game: game, replay: replay, players: planned, options: options, event_count: environment.events.size)
    end
  else
    legacy = T::GameResult.from_replay(game: game, replay: replay, players: planned, options: options, event_count: environment.events.size)
    assert_equal(nil, legacy['scores'])
  end
  modern = T::GameResult.from_replay(game: game, replay: replay, players: planned, options: options,
    event_count: environment.events.size, result_policy: T::GameResult::RESULT_EXPORT_POLICY)
  assert_equal(%w[blue red], modern['participants'])
  assert_equal(1, modern['winners'].size)
  public_scores = game.participant_scores(replay)
  if id == 'domino'
    # These are penalty points (lower wins), not a higher-is-better small score.
    assert_equal(nil, modern['scores'])
  else
    assert_equal(public_scores['Alpha'], modern['scores']['red'])
    assert_equal(public_scores['Beta'], modern['scores']['blue'])
    game.define_singleton_method(:participant_scores) do |_replay|
      public_scores.merge('Alpha' => public_scores['Alpha'] + 1)
    end
    assert_raises(GameRoomGames::Base::Tournaments::InvalidResult) do
      game.tournament_public_unit_scores(replay, options: options)
    end
    game.singleton_class.remove_method(:participant_scores)
  end
  assert_raises(GameRoomGames::Base::Tournaments::InvalidResult) do
    game.tournament_result_from_public_winners(replay, options: options, winners: ['Alpha'])
  end
  table = T::Standings.calculate(units: %w[blue red], results: [modern.slice('participants', 'winners', 'scores').merge('id' => id)], points: T::Standings::MATCH_POINTS)
  assert_equal([2, 0], table.map { |unit| unit['points'] }.sort.reverse)
  # A pure table projection wraps the actual rule result. This is no stored
  # receipt and grants no creation, entry or Runner authority.
  record = {'preview' => {'intent_id' => 'projection', 'source' => {'candidate' => {'format' => 'round_robin'}}},
    'evidence' => {'version' => 2, 'source' => {'result_policy' => T::GameResult::RESULT_EXPORT_POLICY,
      'membership' => {'units' => %w[blue red].map { |team| {'unit_id' => team} }}},
      'plan' => {'matches' => [{'match_id' => 'projection-match', 'leg' => 1, 'players' => planned}]}}}
  receipt = {'record_intent' => 'projection', 'match_id' => 'projection-match', 'leg' => 1, 'summary' => modern}
  team_table = T::LocalFixedTeamStandings.build(record: record, executions: [{'record_intent' => 'projection', 'result' => receipt}])
  assert_equal(true, team_table['complete'])
  assert_equal([2, 0], team_table['standings'].map { |unit| unit['points'] })
  assert_equal(modern['scores'].nil? ? [nil, nil] : modern['scores'].values.sort.reverse,
    team_table['standings'].map { |unit| unit['score_for'] })
  assert_raises(T::Publication::Invalid) do
    T::LocalFixedTeamStandings.build(record: record, executions: [{'record_intent' => 'projection',
      'result' => receipt.merge('match_id' => 'unplanned')}])
  end
  assert_raises(T::Publication::Invalid) do
    T::LocalFixedTeamStandings.build(record: record, executions: [{'record_intent' => 'projection',
      'result' => receipt.merge('summary' => modern.merge('winners' => [], 'draw' => false))}])
  end
  puts "PASS #{id} actual production rule result projected to source teams, 2/0 and game-declared scores; legacy contract unchanged"
end
puts 'Projection-only proof: generic local team execution is not enabled for Domino or Taboo by this test.'
