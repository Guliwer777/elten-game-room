require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
with_fixture(game:'tic_tac_toe',names:%w[Organizator Beta Gamma],rematch:false) do |fixture|
  backend=fixture.backend
  record=backend.accept(preview:backend.preview(publication_ref:fixture.reference,base_seats:fixture.base,intent_id:'consent'))
  intent=record['preview']['intent_id']
  fixture.now=record['evidence']['plan']['matches'].first['windows'].first['opens']+1
  with_dispatch(fixture,record,'Organizator'){|d|d.configure(intent_id:intent,max_tables:3,consent_before_table:true)}
  with_dispatch(fixture,record,'Organizator'){|d|assert_equal(:waiting,d.advance(intent_id:intent)[:state])}
  %w[Organizator Beta Gamma].each{|actor|with_dispatch(fixture,record,actor){|d|d.available(intent_id:intent,available:true)}}
  ready_player=record['evidence']['plan']['matches'].first['players'].first['account']
  first=nil
  with_dispatch(fixture,record,ready_player.capitalize){|d|first=d.advance(intent_id:intent);assert_equal(:awaiting_consent,first[:state])}
  proposal=dispatch_state(fixture)['dispatch']['proposals'][intent].values.first
  assert_equal([],dispatch_state(fixture)['native']['cores'],'A table was created before consent')
  refusing=proposal['players'].find{|actor|actor!=ready_player}
  replacement=(%w[organizator beta gamma]-[refusing,ready_player]).first
  with_dispatch(fixture,record,ready_player.capitalize){|d|assert_equal(:awaiting_consent,d.accept(intent_id:intent)[:state])}
  with_dispatch(fixture,record,refusing.capitalize){|d|assert_equal(:declined,d.decline(intent_id:intent)[:state])}
  state=dispatch_state(fixture)
  assert_equal(false,state['dispatch']['availability'][intent][refusing]['available'])
  assert_equal(true,state['dispatch']['availability'][intent][ready_player]['available'])
  assert_equal([],state['native']['cores'])
  with_dispatch(fixture,record,ready_player.capitalize){|d|assert_equal(:awaiting_consent,d.advance(intent_id:intent)[:state])}
  proposal=dispatch_state(fixture)['dispatch']['proposals'][intent].values.first
  assert_equal([ready_player,replacement].sort,proposal['players'].sort,'Ready partner did not get another opponent')
  with_dispatch(fixture,record,ready_player.capitalize){|d|d.accept(intent_id:intent)}
  assert_equal([],dispatch_state(fixture)['native']['cores'],'One acceptance created a table')
  with_dispatch(fixture,record,replacement.capitalize){|d|assert_equal(:confirmed,d.accept(intent_id:intent)[:state])}
  2.times{%w[Organizator Beta Gamma].each{|actor|with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent)}}}
  assert_equal(1,dispatch_state(fixture)['native']['cores'].size,'Both acceptances must create exactly one table')
end
puts 'PASS local proposals: readiness off initially, no table before both accept, refusal disables only refuser and rematches ready partner'
