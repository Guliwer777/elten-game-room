require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions
sandbox do |c|
 service = c.service
 service.publish(**params(timezone: 'local_test:system'))
 id = service.list['announcements'].first['__id']
 first = service.join(tournament_id: id)
 assert_equal('confirmed', service.withdraw(tournament_id: id)['status'])
 count = c.inserts.size
 assert_equal('confirmed', service.withdraw(tournament_id: id)['status'])
 assert_equal(count, c.inserts.size)
 reopened = c.service(journal: c.reopen_journal)
 second = reopened.join(tournament_id: id)
 assert_equal('confirmed', second['status'])
 assert(first['values']['operation_key'] != second['values']['operation_key'], 'Rejoin reuses departed membership')
 assert_equal(second['evidence']['record_ids'].first, reopened.list['members'].first['registration_id'])
 count = c.inserts.size
 assert_equal(second['id'], reopened.join(tournament_id: id)['id'])
 assert_equal(count, c.inserts.size)
 assert_equal('confirmed', reopened.withdraw(tournament_id: id)['status'])
 third = reopened.join(tournament_id: id)
 assert_equal('confirmed', third['status'])
 assert_equal(1, reopened.list['members'].size)
 c.now = 200
 reopened.withdraw(tournament_id: id)
 error = assert_raises(T::PublicService::Error) { reopened.join(tournament_id: id) }
 assert_equal(:closed, error.code)
end
sandbox do |c|
 service = c.service
 service.publish(**params(timezone: 'local_test:system'))
 id = service.list['announcements'].first['__id']
 service.join(tournament_id: id)
 service.remove_participant(tournament_id: id, account: c.actor)
 assert_equal('confirmed', service.join(tournament_id: id)['status'])
 c.after_insert = ->(_table, values, _id) { raise IOError, 'Lost reply' if values['kind'] == 'withdrawal' }
 assert_raises(T::TablesGateway::UnconfirmedWrite) { service.withdraw(tournament_id: id) }
 c.after_insert = nil
 assert_equal('confirmed', c.service(journal: c.reopen_journal).withdraw(tournament_id: id)['status'])
 assert_equal('confirmed', service.join(tournament_id: id)['status'])
 service.withdraw(tournament_id: id)
 c.after_insert = ->(_table, values, _id) { raise IOError, 'Lost rejoin reply' if values['kind'] == 'join' }
 assert_raises(T::TablesGateway::UnconfirmedWrite) { service.join(tournament_id: id) }
 c.after_insert = nil
 count = c.inserts.size
 assert_equal('confirmed', c.service(journal: c.reopen_journal).join(tournament_id: id)['status'])
 assert_equal(count, c.inserts.size)
end
puts 'PASS rejoin after departure/removal, repeated cycles, restart, deduplication and closed registration'
