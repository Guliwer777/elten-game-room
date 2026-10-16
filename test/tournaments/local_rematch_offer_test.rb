require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
with_fixture(game:'tic_tac_toe',names:%w[Organizator Beta],rematch:true) do |fixture|
  backend=fixture.backend
  record=backend.accept(preview:backend.preview(publication_ref:fixture.reference,base_seats:fixture.base,intent_id:'rematch-offer'))
  intent=record['preview']['intent_id']
  fixture.now=record['evidence']['plan']['matches'].first['windows'].first['opens']+1
  names=%w[Organizator Beta]
  with_dispatch(fixture,record,'Organizator'){|d|d.configure(intent_id:intent,max_tables:2)}
  names.each{|actor|with_dispatch(fixture,record,actor){|d|d.available(intent_id:intent,available:true)}}
  2.times{names.each{|actor|with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent)}}}
  names.each{|actor|with_dispatch(fixture,record,actor){|d|d.accept(intent_id:intent)}}
  names.each{|actor|with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent)}}
  row=dispatch_state(fixture)['executions'].values.find{|value|value['start']}
  finish_dispatch_board(fixture,record,row)
  with_dispatch(fixture,record,'Organizator'){|d|d.configure(intent_id:intent,max_tables:2,consent_before_table:true)}
  with_dispatch(fixture,record,'Organizator') do |d|
    assert_equal(:awaiting_rematch,d.advance(intent_id:intent)[:state])
    assert_equal(:awaiting_rematch,d.accept(intent_id:intent,rematch_only:true)[:state])
  end
  with_dispatch(fixture,record,'Beta'){|d|assert_equal(:declined,d.decline(intent_id:intent,rematch_only:true)[:state])}
  assert_equal(1,dispatch_state(fixture)['native']['cores'].size,'Not now created another table')
  assert_equal(1,dispatch_state(fixture)['executions'].values.count{|value|value['result']},'Not now awarded a result')
  with_dispatch(fixture,record,'Beta'){|d|d.available(intent_id:intent,available:true)}
  with_dispatch(fixture,record,'Organizator'){|d|assert_equal(:awaiting_rematch,d.advance(intent_id:intent)[:state])}
  names.each{|actor|with_dispatch(fixture,record,actor){|d|d.accept(intent_id:intent,rematch_only:true)}}
  names.each{|actor|with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent)}}
  state=dispatch_state(fixture)
  assert_equal(2,state['native']['cores'].size,'Accepted return must use exactly one additional table')
  assert_equal([1,2],state['executions'].values.map{|value|value['request']['leg']}.sort)
end
puts 'PASS local return offer: completed first game, Not now preserves pending leg, explicit Ready and mutual acceptance create the return table'
