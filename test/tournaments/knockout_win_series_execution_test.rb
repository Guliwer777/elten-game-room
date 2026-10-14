require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport
$stdout.sync=true
names=%w[Organizator Beta]
draw=[[0,0],[0,1],[0,2],[1,1],[1,0],[1,2],[2,1],[2,0],[2,2]]
with_fixture(game:'tic_tac_toe',names:names,rematch:false,group_advancement:T::GroupAdvancement::COMPACT,
  knockout_rematch:false,final_rematch:false,final_wins_to:2) do |fixture|
  backend=fixture.backend
  puts 'series: accepting first plan'
  record=backend.accept(preview:backend.preview(publication_ref:fixture.reference,base_seats:fixture.base,intent_id:'win-final'))
  fixture.now=record['evidence']['plan']['matches'].first['windows'].first['opens']+1
  3.times do |attempt|
    puts "series: game #{attempt+1}"
    intent=record['preview']['intent_id']
    with_dispatch(fixture,record,names.first){|d|d.configure(intent_id:intent,max_tables:2)}
    names.each{|actor|with_dispatch(fixture,record,actor){|d|d.available(intent_id:intent,available:true)}}
    2.times{names.each{|actor|with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent)}}}
    names.each{|actor|with_dispatch(fixture,record,actor){|d|assert_equal(:confirmed,d.accept(intent_id:intent)[:state])}}
    names.each{|actor|with_dispatch(fixture,record,actor){|d|d.advance(intent_id:intent)}}
    row=dispatch_state(fixture)['executions'].values.find{|r|r['record_intent']==intent && r['start']}
    assert(row,'Missing game in win series')
    first=row['request']['players'].min_by{|person|person['seat']}['account']
    winning_moves=first=='organizator' ? [[0,0],[1,0],[0,1],[1,1],[0,2]] : [[1,0],[0,0],[1,1],[0,1],[2,2],[0,2]]
    finish_dispatch_board(fixture,record,row,moves:attempt==1 ? draw : winning_moves)
    puts "series: game #{attempt+1} result saved"
    with_individual_execution(fixture,record,names.first) do |execution|
      summary=execution.progress
      if attempt<2
        assert_equal('awaiting_series',summary['knockout_state'])
        preview=execution.knockout_preview
        assert_equal(:confirmed,preview[:state],preview.inspect)
        assert_equal(attempt+2,preview[:plan]['series']['attempt'])
        assert_equal(:confirmed,execution.knockout_accept(preview:preview[:preview])[:state])
        child=execution.knockout_execution_preview
        assert_equal(:confirmed,child[:state],child.inspect)
        accepted=execution.knockout_execution_accept(preview:child[:preview])
        assert_equal(:confirmed,accepted[:state],accepted.inspect)
        record=accepted[:record]
      else
        assert_equal('completed',summary['knockout_state'])
        assert_equal('organizator',summary['champion'])
      end
    end
  end
end
puts 'PASS first-to-two knockout final through native game executor: win, draw, win, next games and final champion'
