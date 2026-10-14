require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport
names = %w[Ala Anna Bartek Beata]
context, service, reference = fixture(names: names, rematch: true, group_advancement: T::GroupAdvancement::AUTOMATIC)
with_backend(context) do |backend, reopen|
  preview = backend.preview_pairs(publication_ref: reference, pairs: names.each_slice(2).to_a,
    team_template: TEMPLATE, intent_id: 'direct-team-final')
  record = backend.accept(preview: preview)
  candidate = record['preview']['source']['candidate']
  assert_equal('knockout', candidate['format'])
  assert_equal('direct_final', candidate['knockout']['origin'])
  assert_equal(false, candidate['rematch'])
  assert_equal(1, candidate['matches'].size)
  assert_equal(4, candidate['matches'].first['players'].size)
  assert_equal(%w[team-001 team-002], candidate['matches'].first['unit_ids'])
  T::FixedTeamPlanContract.source!(record['evidence']['source'])
  assert_equal(record, reopen.call.readback(intent_id: 'direct-team-final'))
end
puts 'PASS direct team final: own signup, full fixed-team accepted execution contract and cold readback'
