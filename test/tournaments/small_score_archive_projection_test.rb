require_relative '../support/tournament_generic_team_round'
include TournamentGenericTeamRoundSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: 'domino', reopen: true)
begin
  bytes = File.binread(generic_team_state_path(fixture))
  state = generic_team_state(fixture)
  assert_equal(2, state['executions'].size)
  state['executions'].values.each do |row|
    core = state['native']['cores'].find { |item| item['id'] == row['start']['native_uuid'] }
    original = T::LocalGameResult.summary(row, core, registry: fixture.registry, result_policy: T::GameResult::DRAW_RESULT_POLICY)
    assert_equal(row['result']['summary'], original)
    assert_equal(nil, original['scores'])
    current = T::LocalGameResult.summary(row, core, registry: fixture.registry, result_policy: T::GameResult::CURRENT_RESULT_POLICY)
    assert_equal('lower', current['score_order'])
    assert_equal(original['winners'], current['winners'])
    assert_equal(original['draw'], current['draw'])
    public_scores = nil
    T::LocalGameResult.with_core(core, row, owner: row['coordinator']) do |_tx, _transport, _table, repository, session|
      snapshot = repository.snapshot_for(session, force_events: true)
      game = fixture.registry.build('domino')
      replay = game.replay(snapshot.session, snapshot.events, repository)
      public_scores = game.participant_scores(replay)
    end
    row['request']['players'].group_by { |person| person['team'] }.each do |team, members|
      assert_equal(3, members.size)
      scores = members.map { |person| public_scores.fetch(person['username']) }
      assert_equal(1, scores.uniq.size)
      assert_equal(scores.first, current['scores'].fetch(team))
    end
    table = T::StandingsRanking.calculate(units: current['participants'],
      results: [current.slice('participants', 'winners', 'scores', 'score_order').merge('id' => row['request']['match_id'])],
      points: T::Standings::MATCH_POINTS, criteria: T::StandingsRanking::CRITERIA)
    assert_equal(current['draw'] ? [1, 1] : [2, 0], table.map { |unit| unit['points'] }.sort.reverse)
    assert_equal(['lower'], table.map { |unit| unit['score_order'] }.uniq)
  end
  assert_equal(bytes, File.binread(generic_team_state_path(fixture)))
  puts 'PASS ordered six-player archive projection: real draw and win, public team penalties counted once, old v3 receipts unchanged, new v4 direction'
ensure
  fixture.close
end
