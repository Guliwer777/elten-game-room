require_relative '../support/tournament_public_service'
require_relative '../../lib/tournaments/public_service'
require_relative '../../lib/tournaments/tournament_lifecycle'
require_relative '../../lib/tournaments/server_match_window'
include TournamentPublicServiceSupport
include GameRoomTest::Assertions

sandbox do |c|
  service=c.service
  owner=c.actor
  options=params(draft:draft.merge('windows'=>[],'starts_at'=>0,'deadline_at'=>200),
    registration_opens_at:0,registration_closes_at:0,timezone:'UTC')
  published=service.publish(**options)
  assert_equal('confirmed',published['status'])
  row=-> {service.list['announcements'].first}
  id=row.call['__id']
  phase=->(action,key) {service.change_phase(tournament_id:row.call['__id'],action:action,intent_id:key,
    expected_generation:T::RegistrationProjection.publication_generation(row.call))}
  assert_equal(:soon,T::TournamentLifecycle.classify(row.call,now:c.now)[:state])
  assert_equal('confirmed',service.register_creator(publication_record:published)['status'])
  c.actor='Guest'
  guest=c.service(journal:c.reopen_journal)
  assert_equal(:not_open,assert_raises(T::PublicService::Error){guest.join(tournament_id:id)}.code)
  c.actor=owner
  c.now+=10
  phase.call('open','open-one')
  c.actor='Guest'
  c.now+=1
  assert_equal('confirmed',guest.join(tournament_id:id)['status'])
  c.actor=owner
  c.now+=1
  closed=phase.call('close','close-one')
  assert_equal('confirmed',closed['status'])
  assert_equal(:waiting,T::TournamentLifecycle.classify(row.call,now:c.now)[:state])
  # A raw late join is retained as rejected evidence, not revived by reopening.
  late={'tournament_id'=>id,'operation_key'=>'late-join','kind'=>'join'}
  # Use the gateway's own insert path for authentic fixture metadata.
  c.actor='Late'
  c.gateway.append('tournament_registrations',late.reject{|key,_|key.start_with?('__')})
  c.actor=owner
  c.now+=1
  phase.call('open','open-two')
  assert_equal(2,service.list['members'].size,'Reopening lost old members or revived a rejected join')
  c.now=400
  started=phase.call('start','start-one')
  assert_equal('confirmed',started['status'])
  current=row.call
  lifecycle=T::TournamentLifecycle.classify(current,now:c.now)
  assert_equal(:running,lifecycle[:state])
  assert_equal(true,lifecycle[:overdue],'The deadline should be informative, not a result')
  reference={'author'=>owner,'publication_key'=>current['publication_key']}
  candidate=service.schedule_candidate(publication_ref:reference).to_h
  assert_equal(2,candidate['roster'].size)
  assert_equal({'opens'=>400,'closes'=>nil},T::ServerMatchWindow.current(candidate,500))
  count=c.inserts.size
  assert_equal('confirmed',service.change_phase(tournament_id:current['__id'],action:'start',intent_id:'start-one',
    expected_generation:T::RegistrationProjection.publication_generation(current))['status'])
  assert_equal(count,c.inserts.size,'Repeated Start appended again')
  assert_equal(:tournament_started,assert_raises(T::PublicService::Error){phase.call('open','after-start')}.code)
  assert_equal('confirmed',service.delete_tournament(tournament_id:current['__id'],intent_id:'cancel')['status'])
  assert_equal([],service.list['announcements'])
end

sandbox do |c|
  service=c.service
  service.publish(**params(draft:draft.merge('windows'=>[],'starts_at'=>200,'deadline_at'=>0),
    registration_opens_at:100,registration_closes_at:0,timezone:'UTC'))
  row=service.list['announcements'].first
  assert_equal(:registration,T::TournamentLifecycle.classify(row,now:199)[:state])
  assert_equal(:running,T::TournamentLifecycle.classify(row,now:200)[:state])
  assert_equal(true,T::TournamentTiming.registration_closed?(row,200))
  assert_equal(nil,T::TournamentLifecycle.ending_at(row))
  assert_equal(200,T::TournamentLifecycle.next_change(row,now:199))
  assert_equal(nil,T::TournamentLifecycle.next_change(row,now:200))
end
puts 'PASS optional timeline: manual/scheduled phases, historical joins, reopen, overdue play, stable start, cancellation'
