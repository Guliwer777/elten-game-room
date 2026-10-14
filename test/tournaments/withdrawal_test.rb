require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions

sandbox do |c|
  service = c.service
  record = service.publish(**params(timezone: 'local_test:system'))
  assert_equal('confirmed', record['status'])
  id = service.list['announcements'].first['__id']
  assert_equal('confirmed', service.join(tournament_id: id)['status'])
  c.now = 201 # Registration is closed, but the tournament has not started.
  result = service.withdraw(tournament_id: id)
  assert_equal('confirmed', result['status'])
  assert(service.list['members'].empty?, 'Withdrawn participant remains registered')
  count = c.inserts.size
  assert_equal('confirmed', service.withdraw(tournament_id: id)['status'])
  assert_equal(count, c.inserts.size)
  error = assert_raises(T::PublicService::Error) { service.join(tournament_id: id) }
  assert_equal(:closed, error.code)
  reopened = c.service(journal: c.reopen_journal)
  assert(reopened.list['members'].empty?, 'Withdrawal is lost after reopening')
end
sandbox do |c|
  service = c.service
  service.publish(**params(timezone: 'local_test:system'))
  row = service.list['announcements'].first
  service.join(tournament_id: row['__id'])
  c.now = T::RegistrationProjection.local_start(row)
  count = c.inserts.size
  error = assert_raises(T::PublicService::Error) { service.withdraw(tournament_id: row['__id']) }
  assert_equal(:tournament_started, error.code)
  assert_equal(count, c.inserts.size)
  assert_equal(1, service.list['members'].size)
end
puts 'PASS durable withdrawal after registration closes; exact tournament-start boundary; no duplicate append'

sandbox do |c|
  service = c.service
  service.publish(**params(timezone: 'UTC'))
  row = service.list['announcements'].first
  id = row['__id']
  service.join(tournament_id: id)
  start = Time.utc(2026, 10, 15, 12, 0).to_i
  assert_equal(start, T::RegistrationProjection.local_start(row))
  c.now = start - 1
  assert_equal('confirmed', service.withdraw(tournament_id: id)['status'])
  assert(service.list['members'].empty?)
end
sandbox do |c|
  service = c.service
  service.publish(**params(timezone: 'UTC'))
  id = service.list['announcements'].first['__id']
  service.join(tournament_id: id)
  c.now = Time.utc(2026, 10, 15, 12, 0).to_i
  count = c.inserts.size
  error = assert_raises(T::PublicService::Error) { service.withdraw(tournament_id: id) }
  assert_equal(:tournament_started, error.code)
  assert_equal(count, c.inserts.size)
end
puts 'PASS UTC withdrawal uses the declared instant and exact start boundary'

sandbox do |c|
  service = c.service
  service.publish(**params(timezone: 'local_test:system'))
  id = service.list['announcements'].first['__id']
  service.join(tournament_id: id)
  c.after_insert = ->(table, values, _id) { raise IOError, 'Lost reply' if values['kind'] == 'withdrawal' }
  assert_raises(T::TablesGateway::UnconfirmedWrite) { service.withdraw(tournament_id: id) }
  c.after_insert = nil
  count = c.inserts.size
  assert_equal('confirmed', c.service(journal: c.reopen_journal).withdraw(tournament_id: id)['status'])
  assert_equal(count, c.inserts.size)
  assert(service.list['members'].empty?)
end
puts 'PASS withdrawal response loss is reconciled after restart without a second write'

sandbox do |c|
  owner = c.actor
  organizer = c.service
  organizer.publish(**params(timezone: 'local_test:system'))
  id = organizer.list['announcements'].first['__id']
  c.actor = 'Beta'
  participant = c.service(journal: c.reopen_journal)
  participant.join(tournament_id: id)
  count = c.inserts.size
  error = assert_raises(T::PublicService::Error) { participant.remove_participant(tournament_id: id, account: 'Beta') }
  assert_equal(:not_organizer, error.code)
  assert_equal(count, c.inserts.size)
  c.actor, c.now = owner, 201
  assert_equal('confirmed', organizer.remove_participant(tournament_id: id, account: 'Beta')['status'])
  assert(organizer.list['members'].empty?, 'Removed participant remains in roster')
  assert(c.service(journal: c.reopen_journal).list['members'].empty?, 'Removal is lost after restart')
end
puts 'PASS organizer-only participant removal survives restart and works after registration closes'
