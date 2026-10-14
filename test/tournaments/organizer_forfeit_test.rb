require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_phase_connection'
include TournamentPhaseConnectionSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'manual-forfeit'))
  revision = nil
  with_individual_execution(fixture, record, 'Alpha') do |execution|
    revision = execution.organizer_result_status[:revision]
    assert_equal(:not_author, execution.organizer_forfeit(operation_id: 'decision', winner: 'alpha', reason: 'No show', expected_revision: revision)[:reason])
  end
  with_individual_execution(fixture, record, 'Organizator') do |execution|
    assert_equal(:stale_view, execution.organizer_forfeit(operation_id: 'decision', winner: 'alpha', reason: 'No show', expected_revision: 'old')[:reason])
    result = execution.organizer_forfeit(operation_id: 'decision', winner: 'alpha', reason: 'No show', expected_revision: revision)
    assert_equal(:confirmed, result[:state], result.inspect)
    assert_equal(nil, result[:effect]['summary']['scores'])
    repeated = execution.organizer_forfeit(operation_id: 'decision', winner: 'alpha', reason: 'No show', expected_revision: revision)
    assert_equal(result[:effect], repeated[:effect])
    assert_equal(:result_already_recorded, execution.organizer_forfeit(operation_id: 'another', winner: 'beta', reason: 'Changed mind', expected_revision: revision)[:reason])
    standings = execution.progress['standings']
    assert_equal([0, 2], standings.map { |row| row['points'] }.sort)
    assert(standings.all? { |row| row['score_for'].nil? && row['score_against'].nil? }, 'Forfeit awarded small points')
  end
  with_individual_execution(fixture, record, 'Organizator') do |execution|
    assert_equal('forfeit', execution.organizer_result_status[:result]['kind'])
    assert_equal(true, execution.progress['complete'])
  end
  match = record['evidence']['plan']['matches'].first
  selectors = {intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id']}
  with_phase_connection(fixture, 'Organizator') do |connection|
    status = connection.perform(action: :organizer_result_status, selectors: selectors)[:operation]
    assert_equal('decision', status[:result]['id'])
    assert_equal(:result_already_recorded, connection.perform(action: :organizer_forfeit, selectors: selectors,
      operation_id: 'new', winner: 'beta', reason: 'Cannot overwrite', expected_revision: status[:revision])[:operation][:reason])
  end
end
puts 'PASS organizer-only forfeit: 2/0, no small points, stale guard, one decision, cold read and immutable result'
