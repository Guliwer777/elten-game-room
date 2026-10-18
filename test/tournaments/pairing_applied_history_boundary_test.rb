require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions

T = GameRoomTournaments
registry = GameRoomGames::CATALOG
values = params('spades', timezone: 'UTC')
values[:draft] = values[:draft].merge('players_per_match' => 4,
  'game_options' => registry.build('spades').normalize_options('team_size' => 2))
announcement = T::Publication.from_draft(**values.reject { |k, _| k == :intent_id },
  registry: registry, publication_key: 'independent-pairs').to_row.merge(
    '__id' => 10, '__insertion_time' => 90, '__insertion_user' => 'Organizer')
announcements = [announcement, announcement.merge('__id' => 11)]
people = %w[alpha beta gamma delta]
rows = people.each_with_index.map do |name, i|
  {'__id' => i + 1, '__insertion_time' => 100, '__insertion_user' => name,
   'tournament_id' => 10, 'kind' => 'join', 'operation_key' => "join-#{name}"}
end
generation = T::RegistrationProjection.pairing_generation(people, {})
pair = lambda do |id, author, account, partner, key, gen = generation, tournament = 10|
  {'__id' => id, '__insertion_time' => 150, '__insertion_user' => author,
   'tournament_id' => tournament, 'kind' => 'pairing', 'operation_key' => key,
   'account' => account, 'partner' => partner, 'pairing_generation' => gen}
end
build = ->(events) { T::RegistrationProjection.build(announcements: announcements,
  registrations: events, registry: registry, complete: true) }
request = pair.call(20, 'alpha', 'alpha', 'beta', 'same-user-key')
confirmation = pair.call(21, 'beta', 'beta', 'alpha', 'same-user-key')
stale = pair.call(22, 'Organizer', 'gamma', 'delta', 'stale-organizer')
events = rows + [request, confirmation, stale]
projection = build.call(events)
assert_equal([%w[alpha beta]], projection.to_h['pairs'].map { |r| r['accounts'] })
assert(projection.pairing_applied?(account: 'ALPHA', operation_key: 'same-user-key'), 'A saved request counts even before a team exists')
assert(projection.pairing_applied?(account: 'Beta', operation_key: 'same-user-key'), 'Keys are scoped to authenticated author')
assert_equal(false, projection.pairing_applied?(account: 'Organizer', operation_key: 'stale-organizer'))
assert_equal(false, projection.pairing_applied?(account: 'gamma', operation_key: 'same-user-key'))

# A late exact retry through the publication alias is ignored by the generation
# guard, but must not erase the first successful decision from history.
aliases = (100..169).map { |id| confirmation.merge('__id' => id, 'tournament_id' => 11) }
departure = {'__id' => 200, '__insertion_time' => 160, '__insertion_user' => 'alpha',
  'tournament_id' => 11, 'kind' => 'withdrawal', 'operation_key' => 'alpha-left'}
copy_before = Marshal.dump(events + aliases + [departure])
cold = build.call((events + aliases + [departure]).reverse)
assert_equal([], cold.to_h['pairs'])
assert(cold.pairing_applied?(account: 'beta', operation_key: 'same-user-key'), 'Later departure cannot undo historical success')
assert_equal(false, cold.pairing_applied?(account: 'Organizer', operation_key: 'stale-organizer'))
assert_equal(copy_before, Marshal.dump(events + aliases + [departure]), 'No projection mutation of evidence')
retained = cold.with_retained_announcements([])
assert(retained.pairing_applied?(account: 'beta', operation_key: 'same-user-key'), 'Retention hides the tournament, not stored evidence')
assert(cold.to_h.frozen?)

# An alias with another target poisons its own operation, not other authors.
bad = confirmation.merge('__id' => 300, 'partner' => 'gamma')
conflict = build.call(events + [bad])
assert_equal('conflict', conflict.operation_status(tournament_id: 11, account: 'beta', operation_key: 'same-user-key'))
assert_equal(false, conflict.pairing_applied?(account: 'beta', operation_key: 'same-user-key'))
assert(conflict.pairing_applied?(account: 'alpha', operation_key: 'same-user-key'))

# Real local gateway, durable journal and lost-ACK boundary. A withdrawal which
# races the INSERT invalidates the global generation, not the stored UUID.
sandbox do |context|
  context.actor = 'Organizer'
  service = -> { context.service(journal: context.reopen_journal) }
  publication = service.call.publish(**values)
  id = publication['evidence']['canonical_id']
  people.each do |person|
    context.actor = person
    service.call.join(tournament_id: id)
  end
  context.actor = 'alpha'
  service.call.set_partner(tournament_id: id, account: 'alpha', partner: 'beta', intent_id: 'request')
  context.actor = 'beta'
  context.before_insert = lambda do |table, row|
    next unless table == REG && row['kind'] == 'pairing'
    context.before_insert = nil
    context.actor = 'gamma'
    service.call.withdraw(tournament_id: id)
    context.actor = 'beta'
  end
  context.after_insert = lambda do |table, row, _result|
    next unless table == REG && row['kind'] == 'pairing'
    context.after_insert = nil
    raise T::LocalTestTables::Error, :lost_pairing_ack
  end
  begin
    service.call.set_partner(tournament_id: id, account: 'beta', partner: 'alpha', intent_id: 'uncertain-old')
    raise 'Expected lost ACK'
  rescue T::TablesGateway::UnconfirmedWrite
    # Recovery must use the original attempt, never another INSERT.
  end
  journal = context.reopen_journal
  attempted = journal.find(kind: 'pairing', intent_id: 'uncertain-old')
  assert_equal('attempted', attempted['status'])
  writes = context.inserts.size
  resolved = service.call.reconcile(operation_id: attempted['id'])
  assert_equal('confirmed', resolved['status'])
  assert_equal(false, resolved.dig('evidence', 'pairing_applied'))
  assert_equal(writes, context.inserts.size)
  assert_equal(attempted['values'], resolved['values'])

  fresh = service.call.set_partner(tournament_id: id, account: 'beta', partner: 'alpha', intent_id: 'new-explicit-choice')
  assert_equal(true, fresh.dig('evidence', 'pairing_applied'))
  context.actor = 'Organizer'
  service.call.set_partner(tournament_id: id, account: 'beta', partner: 'delta', intent_id: 'later-organizer-choice')
  context.actor = 'beta'
  assert_equal([%w[beta delta]], service.call.list['pairs'].map { |r| r['accounts'] })
  writes = context.inserts.size
  assert_equal(false, service.call.reconcile(operation_id: attempted['id']).dig('evidence', 'pairing_applied'))
  assert_equal(true, service.call.reconcile(operation_id: fresh['id']).dig('evidence', 'pairing_applied'))
  assert_equal(writes, context.inserts.size)
  context.available = false
  before = File.binread(journal.path)
  begin
    service.call.reconcile(operation_id: attempted['id'])
    raise 'Expected unavailable gateway'
  rescue T::TablesGateway::Error
  end
  assert_equal(before, File.binread(journal.path), 'A failed observation cannot replace known outcome evidence')
end
puts 'PASS independent pairing history: aliases, authors, changed target, departure, retention, lost ACK, cold journal and no automatic resubmission'
