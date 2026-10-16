require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_phase_connection'
require_relative '../../lib/tournaments/local_match_labels'
include TournamentPhaseConnectionSupport
[[true,false],[false,true]].each do |knockout_return, final_return|
  with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta Gamma Delta], rematch: true,
    group_advancement: T::GroupAdvancement::COMPACT, knockout_rematch: knockout_return, final_rematch: final_return) do |fixture|
    backend = fixture.backend
    root = backend.accept(preview: backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'round-rematch'))
    fixture.now = root['evidence']['plan']['matches'].first['windows'].first['opens'] + 1
    record = root
    counts = [4, knockout_return ? 4 : 2, final_return ? 2 : 1]
    3.times do |round|
      phase = ['Group stage', 'Knockout round %{number}', 'Final'].fetch(round)
      expected_phase = GameRoomContent.utf8(GameRoomLocalization.translate(phase)) % {number: 1}
      assert_equal(expected_phase, T::LocalMatchLabels.phase(record))
      assert_equal(counts[round], record['evidence']['plan']['matches'].size)
      record['evidence']['plan']['matches'].each_with_index do |match,index|
        assert_equal(index + 1, T::LocalMatchLabels.number(record, match))
        label = T::LocalMatchLabels.match(record, match)
        assert(!label.match?(/[a-f0-9]{64}/), 'Match label contains storage digest')
        if match['leg'] == 2
          expected = GameRoomContent.utf8(GameRoomLocalization.translate('Match %{number}, return match: %{players}')) % {
            number: index + 1, players: match['players'].map { |p| p['username'] }.join(' — ')}
          assert_equal(expected, label)
        end
        with_individual_execution(fixture, record, 'Organizator') do |e|
          e.select_for_reconcile(intent_id: record['preview']['intent_id'], match_id: match['match_id'], leg: match['leg'], window_id: match['windows'].first['id'])
          status = e.organizer_result_status
          winner = match['players'].map { |p| p['account'] }.min
          assert_equal(:confirmed, e.organizer_forfeit(operation_id: "decision-#{round}-#{index}", winner: winner,
            reason: 'Explicit organizer lifecycle test', expected_revision: status[:revision])[:state])
        end
      end
      with_phase_connection(fixture, 'Organizator') do |connection|
        value = connection.advance_tournament(publication_ref: fixture.reference, root_intents: [root['preview']['intent_id']])[:transitions].first
        if round == 2
          assert_equal(:tournament_completed, value[:reason])
          assert(connection.tournament_branch_catalog(publication_ref: fixture.reference, root_intents: [root['preview']['intent_id']]).last['progress']['champion'], 'Missing final champion')
        else
          assert_equal(:confirmed, value[:state], value.inspect)
          record = value[:record]
        end
      end
    end
    assert_equal(root, fixture.backend(context: nil).readback(intent_id: root['preview']['intent_id']))
  end
end
puts 'PASS independent group/knockout/final return policy: both combinations, series winner, champion, cold immutable lineage'
