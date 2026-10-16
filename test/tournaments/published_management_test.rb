require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions
sandbox do |c|
 service = c.service
 service.publish(**params(timezone: 'local_test:system'))
 row = service.list['announcements'].first
 changed = draft.merge('name'=>'Changed tournament')
 result = service.edit_tournament(tournament_id: row['__id'], **params(draft: changed, intent_id: 'edit-one', timezone: 'local_test:system', registration_closes_at: 250))
 assert_equal('confirmed', result['status'])
 assert_equal('Changed tournament', service.list['announcements'].first['title'])
 assert_equal(250, c.service(journal: c.reopen_journal).list['announcements'].first['registration_closes_at'])
 count = c.inserts.size
 error = assert_raises(T::PublicService::Error) { service.delete_tournament(tournament_id: row['__id'], intent_id: 'stale-delete', expected_generation: T::RegistrationProjection.publication_generation(row)) }
 assert_equal(:source_changed, error.code)
 assert_equal(count, c.inserts.size)
 c.actor = 'Other'
 other = c.service(journal: c.reopen_journal)
 assert_equal(1, other.list['announcements'].size)
 error = assert_raises(T::PublicService::Error) { other.delete_tournament(tournament_id: row['__id'], intent_id: 'forbidden') }
 assert_equal(:not_organizer, error.code)
 c.now = 225
 assert_equal('confirmed', other.join(tournament_id: row['__id'])['status'])
 c.actor = c.journal.owner
 assert_equal('confirmed', service.delete_tournament(tournament_id: row['__id'], intent_id: 'delete-one')['status'])
 assert(service.list['announcements'].empty?, 'Deleted tournament still listed')
 assert(c.service(journal: c.reopen_journal).list['announcements'].empty?, 'Deleted tournament reappeared')
 count = c.inserts.size
 assert_equal('confirmed', service.delete_tournament(tournament_id: row['__id'], intent_id: 'delete-one')['status'])
 assert_equal(count, c.inserts.size)
end
sandbox do |c|
 service = c.service
 service.publish(**params(timezone: 'local_test:system'))
 row = service.list['announcements'].first
 c.after_insert = ->(_table, values, _id) { raise IOError, 'Lost deletion reply' if values['kind'] == 'cancellation' }
 assert_raises(T::TablesGateway::UnconfirmedWrite) { service.delete_tournament(tournament_id: row['__id'], intent_id: 'lost-delete') }
 c.after_insert = nil
 count = c.inserts.size
 assert_equal('confirmed', c.service(journal: c.reopen_journal).delete_tournament(tournament_id: row['__id'], intent_id: 'lost-delete')['status'])
 assert_equal(count, c.inserts.size)
 assert(service.list['announcements'].empty?, 'Uncertain deletion was not reconciled')
end
puts 'PASS published edit, extended registration, public discovery, author-only deletion and cold reopen'
