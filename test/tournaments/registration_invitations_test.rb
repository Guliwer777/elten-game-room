require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
require_relative '../../lib/tournaments/tournament_event_notice'
require_relative '../../lib/tournaments/tournament_start_publisher'
include GameRoomTest::Assertions
include TournamentPublicServiceSupport
T = GameRoomTournaments
sandbox do |c|
  organizer = c.actor
  owner = c.service
  published = owner.publish(**params(draft: draft.merge('windows'=>[], 'starts_at'=>0, 'deadline_at'=>0), registration_closes_at: 0))
  id = published.fetch('evidence').fetch('canonical_id')
  receipt = owner.invite(tournament_id: id, recipient: 'Peterman', intent_id: 'invite-one')
  assert_equal('confirmed', receipt['status'])
  assert_equal('invitation', receipt['kind'])
  key = receipt['values']['operation_key']
  assert_equal('Peterman', owner.list.fetch('invitations').first['username'])
  assert(owner.list['members'].empty?, 'Invitation registered a participant')
  inserts = c.inserts.size
  repeated = owner.invite(tournament_id: id, recipient: 'Peterman', intent_id: 'invite-one')
  assert_equal(receipt.values_at('id', 'values', 'status'), repeated.values_at('id', 'values', 'status'))
  assert_equal(inserts, c.inserts.size, 'Repeated invitation sent another record')
  assert_equal(:already_invited, assert_raises(T::PublicService::Error) { owner.invite(tournament_id: id, recipient: 'PETERMAN', intent_id: 'another-send') }.code)
  reference = {'author'=>organizer.downcase, 'publication_key'=>published['values']['publication_key']}
  scope = {'account'=>organizer.downcase, 'account_epoch'=>'one', 'backend_identity'=>c.provider.backend_identity}
  notice_service = -> { T::TournamentEventNotice.new(kind:'registration', source:->(_){c.service(journal:c.reopen_journal).notification_context(publication_ref:reference)},
    context:-> {scope}, clock:-> {c.now}, registry:GameRoomGames::CATALOG) }
  notice = notice_service.call.notices(publication_ref:reference, recipient:'Peterman', invitation_key:key).first
  assert_equal(2, notice['version'])
  assert_equal(0, notice_service.call.inspect(metadata:notice, sender:organizer, delivery:true)['expires_at'])
  c.now += 8 * 86400
  assert_equal(key, notice_service.call.notices(publication_ref:reference,recipient:'Peterman',invitation_key:key).first['invitation_key'])
  c.actor = 'Peterman'
  scope = scope.merge('account'=>'peterman','account_epoch'=>'two')
  receiver = c.service(journal:c.reopen_journal)
  service = notice_service.call
  assert(service.presentable?(service.inspect(metadata:notice,sender:organizer)), 'Open registration invitation expired after seven days')
  assert_raises(T::ProposalNotice::Stale) { service.inspect(metadata:notice,sender:'Mallory') }
  refused = receiver.decline_invitation(tournament_id:id,invitation_key:key,intent_id:'decline-one')
  assert_equal('confirmed',refused['status'])
  assert_equal('declined',receiver.list.fetch('invitations').first['status'])
  assert_raises(T::ProposalNotice::Stale) { service.inspect(metadata:notice,sender:organizer) }
  c.actor = organizer
  owner = c.service(journal:c.reopen_journal)
  assert_equal(:already_invited, assert_raises(T::PublicService::Error) { owner.invite(tournament_id:id,recipient:'Peterman',intent_id:'after-decline') }.code)
  c.actor = 'Mallory'
  attacker = c.service(journal:c.reopen_journal)
  assert_raises(T::PublicService::Error) { attacker.invite(tournament_id:id,recipient:'Bob',intent_id:'forged-owner') }
  assert_raises(T::PublicService::Error) { attacker.decline_invitation(tournament_id:id,invitation_key:key,intent_id:'forged-decline') }
  c.actor = 'Peterman'
  receiver = c.service(journal:c.reopen_journal)
  assert_equal('confirmed',receiver.join(tournament_id:id)['status'], 'Declining an invitation banned public registration')
  assert(receiver.list.fetch('invitations').first['resolved'], 'Joining did not consume invitation')
  assert_equal('confirmed',receiver.withdraw(tournament_id:id)['status'])
  assert(receiver.list.fetch('invitations').first['resolved'], 'Withdrawal resurrected invitation')
  c.actor = organizer
  owner = c.service(journal:c.reopen_journal)
  assert_equal(:already_invited, assert_raises(T::PublicService::Error) { owner.invite(tournament_id:id,recipient:'Peterman',intent_id:'after-withdrawal') }.code)
end
puts 'PASS persistent invitations: authenticated send/decline, no re-invites, case-preserving names, no seven-day limit, join/withdrawal and no membership side effects'
