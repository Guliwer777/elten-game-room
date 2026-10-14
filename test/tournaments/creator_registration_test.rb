require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions
sandbox do |context|
  service = context.service
  record = service.publish(**params(registration_opens_at: 160, timezone: 'local_test:system'))
  assert_equal('confirmed', record['status'])
  assert_equal(nil, service.register_creator(publication_record: record.merge('status' => 'unconfirmed')))
  registered = service.register_creator(publication_record: record)
  assert_equal('confirmed', registered['status'])
  snapshot = service.list
  assert_equal([context.actor.downcase], snapshot['members'].map { |member| member['account'] })
  assert_equal(registered['id'], service.register_creator(publication_record: record)['id'])
  assert_equal(1, context.inserts.count { |name, _values| name == REG })
  author = context.actor
  context.actor = 'Another player'
  other = context.service(journal: context.reopen_journal)
  error = assert_raises(T::PublicService::Error) { other.join(tournament_id: snapshot['announcements'].first['__id']) }
  assert_equal(:not_open, error.code)
  context.actor = author
  assert_equal('confirmed', service.withdraw(tournament_id: snapshot['announcements'].first['__id'])['status'])
  assert_equal('withdrawn', service.register_creator(publication_record: record)['status'])
  assert_equal([], service.list['members'])
end
sandbox do |context|
  service = context.service
  record = service.publish(**params(timezone: 'local_test:system'))
  context.after_insert = ->(*) { raise T::LocalTestTables::Error, :store_io_error }
  assert_equal('attempted', service.register_creator(publication_record: record)['status'])
  context.after_insert = nil
  recovered = context.service(journal: context.reopen_journal).register_creator(publication_record: record)
  assert_equal('confirmed', recovered['status'])
  assert_equal(1, context.inserts.count { |name, _values| name == REG })
  assert_equal(1, service.list['members'].size)
end
puts 'PASS creator enrollment before registration opens, no duplicate, ordinary deadline and no forced reenrollment'
