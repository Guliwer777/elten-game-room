require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta Charlie Delta Echo Foxtrot Golf Hotel India],
  rematch: true, group_advancement: T::GroupAdvancement::COMPACT) do |fixture|
  backend = fixture.backend
  shown = backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'compact-accepted')
  record = backend.accept(preview: shown)
  candidate = record['preview']['source']['candidate']
  assert_equal(T::GroupAdvancement::COMPACT, candidate['group_advancement'])
  assert_equal([3,3,3], candidate['groups'].map { |g| g['units'].size })
  assert_equal([1,1,1], candidate['groups'].map { |g| g['places'] })
  assert_equal(18, record['evidence']['plan']['matches'].size)
  cold = fixture.backend(context: nil)
  assert_equal(record, cold.readback(intent_id: 'compact-accepted'))
end
puts 'PASS real nine-player publication, registration, accepted compact groups, return matches and cold readback'
