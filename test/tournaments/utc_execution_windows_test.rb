require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_local_execution_plan'
require_relative '../support/tournament_fixed_teams'
require_relative '../../lib/tournaments/local_execution_plan_backend'
require_relative '../../lib/tournaments/local_fixed_team_plan_backend'
include TournamentLocalExecutionPlanSupport

with_fixture(timezone: 'UTC') do |fixture|
  backend = fixture.backend
  preview = backend.preview(publication_ref: fixture.reference, base_seats: fixture.base, intent_id: 'utc-individual')
  expected = Time.utc(2026, 10, 15, 12).to_i
  assert_equal(expected, preview['windows'].first['opens'])
  assert_equal('utc-window-v1', preview['windows'].first['policy_ref'])
  record = backend.accept(preview: preview)
  assert_equal(record, fixture.backend.readback(intent_id: 'utc-individual'))
  assert_equal(expected, record['evidence']['plan']['matches'].first['windows'].first['opens'])
end
puts 'PASS UTC individual windows survive durable plan acceptance and reopening'

include TournamentFixedTeamsSupport
context, service, reference = fixture(timezone: 'UTC')
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
first = source['candidate']['matches'].select { |match| match['leg'] == 1 }
base_rows = [%w[beata anna bartek ala], %w[ala cezary anna celina], %w[celina beata cezary bartek]]
base = first.zip(base_rows).to_h { |match, accounts| [match['match_id'], accounts] }
with_backend(context) do |backend, reopen, *_|
  preview = backend.preview(publication_ref: reference, membership: membership, team_template: TEMPLATE, base_seats: base, intent_id: 'utc-pairs')
  assert_equal(Time.utc(2026, 10, 15, 12).to_i, preview['windows'].first['opens'])
  assert_equal('utc-window-v1', preview['windows'].first['policy_ref'])
  record = backend.accept(preview: preview)
  assert_equal(record, reopen.call.readback(intent_id: 'utc-pairs'))
end
puts 'PASS UTC fixed-pair windows survive durable plan acceptance and reopening'
