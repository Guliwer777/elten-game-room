require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_team_dispatch'
include TournamentTeamDispatchSupport
names = (1..18).map { |i| "Player#{i.to_s.rjust(2,'0')}" }
context, _service, reference = fixture(names: names, rematch: false, group_advancement: T::GroupAdvancement::COMPACT)
root = nil
with_backend(context) do |backend|
  root = backend.accept(preview: backend.preview_pairs(publication_ref: reference, pairs: names.each_slice(2).to_a,
    team_template: TEMPLATE, intent_id: 'team-group-tie'))
end
record = root
2.times do |round|
  assert_equal(round == 0 ? 9 : 3, record['evidence']['plan']['matches'].size)
  record['evidence']['plan']['matches'].each_with_index do |match,index|
    with_team_match(context, record, 'Organizator', index) do |execution|
      status = execution.organizer_result_status
      winner = match['players'].map { |p| p['team'] }.uniq.min
      result = execution.organizer_forfeit(operation_id: "team-decision-#{round}-#{index}", winner: winner,
        reason: 'Explicit organizer pair test', expected_revision: status[:revision])
      assert_equal(:confirmed, result[:state], result.inspect)
    end
  end
  with_team_match(context, record, 'Organizator') do |execution|
    progress = execution.progress
    assert(progress['standings'].all? { |r| r['score_for'].nil? && r['score_against'].nil? }, 'Team forfeits invented small points')
    shown = execution.knockout_preview
    assert_equal(:confirmed, shown[:state], shown.inspect)
    assert_equal(:confirmed, execution.knockout_accept(preview: shown[:preview])[:state])
    preview = execution.knockout_execution_preview
    assert_equal(:confirmed, preview[:state], preview.inspect)
    next_round = execution.knockout_execution_accept(preview: preview[:preview])
    assert_equal(:confirmed, next_round[:state], next_round.inspect)
    record = next_round[:record]
  end
end
assert_equal(4, record['preview']['source']['candidate']['membership']['units'].size)
assert_equal(8, record['evidence']['source']['roster'].size)
assert_equal(2, record['evidence']['plan']['matches'].size)
record['evidence']['plan']['matches'].each do |match|
  assert_equal([2,2], match['players'].group_by { |p| p['team'] }.values.map(&:size))
end
with_backend(context) { |backend| assert_equal(root, backend.readback(intent_id: root['preview']['intent_id'])) }
puts 'PASS nine pairs: group tie, extra round, restore already-qualified teams, complete paired semifinal roster, no small points and immutable group plan'
