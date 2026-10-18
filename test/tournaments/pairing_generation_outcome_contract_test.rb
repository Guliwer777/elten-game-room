require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions

sandbox do |context|
  context.actor = 'Organizer'
  service = -> { context.service(journal: context.reopen_journal) }
  values = params('spades', timezone: 'UTC')
  values[:draft] = values[:draft].merge('players_per_match' => 4,
    'game_options' => GameRoomGames::CATALOG.build('spades').normalize_options({'team_size' => 2}))
  publication = service.call.publish(**values)
  id = publication.fetch('evidence').fetch('canonical_id')
  %w[Alpha Beta Gamma Delta].each do |actor|
    context.actor = actor
    assert_equal('confirmed', service.call.join(tournament_id: id)['status'])
  end
  pair = lambda do |actor, partner, intent|
    context.actor = actor
    service.call.set_partner(tournament_id: id, account: actor, partner: partner, intent_id: intent)
  end
  pair.call('Alpha', 'Beta', 'first-request')
  pair.call('Gamma', 'Delta', 'second-request')
  first_confirmation = nil
  context.before_insert = lambda do |table, row|
    next unless table == REG && row['kind'] == 'pairing' && row['account'] == 'delta'
    context.before_insert = nil
    first_confirmation = pair.call('Beta', 'Alpha', 'first-confirmation')
    context.actor = 'Delta'
  end
  second_confirmation = pair.call('Delta', 'Gamma', 'second-confirmation')
  # Both writes are durable. Only the first passed the historical pairing
  # generation; a successful insert is not a successful partner selection.
  assert_equal('confirmed', second_confirmation['status'])
  assert_equal([%w[alpha beta]], service.call.list['pairs'].map { |row| row['accounts'] })
  assert_equal(false, second_confirmation.dig('evidence', 'pairing_applied'),
    'A stale partner selection must not be reported as applied')
  assert_equal(true, first_confirmation.dig('evidence', 'pairing_applied'))
  assert(service.call.list['pair_requests'].any? { |row| row['from'] == 'gamma' && row['to'] == 'delta' })
  inserts = context.inserts.size
  retry_result = pair.call('Delta', 'Gamma', 'second-confirmation')
  assert_equal(second_confirmation['id'], retry_result['id'])
  assert_equal(false, retry_result.dig('evidence', 'pairing_applied'))
  assert_equal(inserts, context.inserts.size, 'Readback of the old intent must not submit a fresh choice')
  new_choice = pair.call('Delta', 'Gamma', 'second-confirmation-after-refresh')
  assert_equal(true, new_choice.dig('evidence', 'pairing_applied'))
  assert_equal([%w[alpha beta], %w[delta gamma]], service.call.list['pairs'].map { |row| row['accounts'] })
  # Later success cannot retroactively make the earlier, ignored choice valid.
  old_choice = service.call.reconcile(operation_id: second_confirmation['id'])
  assert_equal(false, old_choice.dig('evidence', 'pairing_applied'))
  context.actor = 'Beta'
  old_success = service.call.reconcile(operation_id: first_confirmation['id'])
  assert_equal(true, old_success.dig('evidence', 'pairing_applied'))
end
puts 'PASS partner generation outcomes: durable stale choice differs from applied pair, readback is non-writing, explicit fresh choice works'
