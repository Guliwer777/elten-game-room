# encoding: UTF-8
require_relative '../support/tournament_fixed_teams'
include TournamentFixedTeamsSupport

context, service, reference = fixture
assert(service.respond_to?(:fixed_team_execution_source), 'RED_FT1: brak publicznego źródła jawnych stałych ekip')
context.reads.clear
source = service.fixed_team_execution_source(publication_ref: reference, membership: membership, team_template: TEMPLATE)
assert_equal(%w[tournament_announcements tournament_registrations], context.reads, 'Jedna projekcja i dwa logiczne odczyty')
candidate = source.fetch('candidate')
expected = [
  [%w[unit-A unit-B], %w[ala anna bartek beata], 1],
  [%w[unit-A unit-C], %w[ala anna celina cezary], 1],
  [%w[unit-B unit-C], %w[bartek beata celina cezary], 1],
  [%w[unit-A unit-B], %w[ala anna bartek beata], 2],
  [%w[unit-A unit-C], %w[ala anna celina cezary], 2],
  [%w[unit-B unit-C], %w[bartek beata celina cezary], 2]
]
assert_equal(expected, candidate.fetch('matches').map { |match| match.values_at('unit_ids', 'players', 'leg') }, 'Całe jednostki AB/AC/BC, obie nogi')
assert_equal('fixed-teams', candidate['source_kind'])
assert_equal(1, candidate['source_version'])
assert_equal(NAMES, source['projection']['members'].map { |person| person['username'] })
assert_equal(false, candidate['dispatch_allowed'])
assert_equal(false, candidate['start_allowed'])
oracle_file('oracle.json', {'source' => source, 'expected_matches' => expected})
puts 'FT1: rzeczywista projekcja i pełne pary jednostek — OK'
