require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
names=%w[Organizator Beta Gamma]
with_fixture(game:'tic_tac_toe',names:names,rematch:false) do |fixture|
  backend=fixture.backend
  record=backend.accept(preview:backend.preview(publication_ref:fixture.reference,base_seats:fixture.base,intent_id:'proposal-recovery'))
  intent=record['preview']['intent_id']
  fixture.now=record['evidence']['plan']['matches'].first['windows'].first['opens']+1
  with_dispatch(fixture,record,'Organizator'){|d|d.configure(intent_id:intent,max_tables:3,consent_before_table:true)}
  names.each{|name|with_dispatch(fixture,record,name){|d|d.available(intent_id:intent,available:true)}}
  actor=record['evidence']['plan']['matches'].first['players'].first['username']
  first=nil
  with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent);first=d.snapshot(intent_id:intent)['proposal']}
  assert(first,'Missing initial proposal')
  with_dispatch(fixture,record,actor){|d|assert_equal(first,d.snapshot(intent_id:intent)['proposal'],'Cold client changed an unexpired proposal')}
  with_dispatch(fixture,record,actor) do |d|
    d.available(intent_id:intent,available:false)
    d.available(intent_id:intent,available:true)
    d.advance(intent_id:intent)
    renewed=d.snapshot(intent_id:intent)['proposal']
    assert(first['token']!=renewed['token'],'Withdraw/rejoin reused stale consent token')
    assert_raises(T::CoordinationContract::Blocked){d.accept(intent_id:intent,expected_proposal:first['token'],require_expected:true)}
    assert_raises(T::CoordinationContract::Blocked){d.decline(intent_id:intent,expected_proposal:first['token'],require_expected:true)}
    assert_equal(true,d.snapshot(intent_id:intent)['own_ready'],'Stale refusal withdrew current readiness')
    assert_equal([],d.snapshot(intent_id:intent)['proposal']['accepted'])
  end
  fixture.now+=61
  with_dispatch(fixture,record,actor) do |d|
    expired=d.snapshot(intent_id:intent)
    assert_equal(false,expired['own_ready'])
    assert_equal(nil,expired['proposal'],'Expired proposal blocks future matching')
    assert_equal([],dispatch_state(fixture)['native']['cores'],'Recovery created a table')
  end
  names.each{|name|with_dispatch(fixture,record,name){|d|d.available(intent_id:intent,available:true)}}
  with_dispatch(fixture,record,actor) do |d|
    assert_equal(:awaiting_consent,d.advance(intent_id:intent)[:state])
    fresh=d.snapshot(intent_id:intent)['proposal']
    assert(first['token']!=fresh['token'],'Expired readiness reused proposal token')
    assert_equal(:awaiting_consent,d.accept(intent_id:intent,expected_proposal:fresh['token'],require_expected:true)[:state])
  end
  ending=record['evidence']['plan']['matches'].first['windows'].first['closes']
  fixture.now=ending-2
  names.each{|name|with_dispatch(fixture,record,name){|d|d.available(intent_id:intent,available:true)}}
  with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent);assert(d.snapshot(intent_id:intent)['proposal'],'Proposal missing before window closure')}
  fixture.now=ending
  with_dispatch(fixture,record,actor) do |d|
    assert_equal(nil,d.snapshot(intent_id:intent)['proposal'],'Closed window retained a playable proposal')
    assert_equal([],dispatch_state(fixture)['native']['cores'],'Window expiry created a table or game')
  end
end
puts 'PASS cold proposal recovery: retained valid proposal, withdraw/rejoin and lease expiry, stale accept/refuse rejected, no table or automatic consent'
