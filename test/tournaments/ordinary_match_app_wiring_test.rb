require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/settings_widget'
require_relative '../support/assertions'
include GameRoomTest::Assertions
app=EltenGameRoom.new
%i[open_ordinary_tournament_match ordinary_tournament_results reconcile_ordinary_tournament_operation].each do |name|
  assert(app.respond_to?(name), "Tournament window cannot call #{name}")
end
service=Object.new
calls=[]
table={'__id'=>7,'__live_session_id'=>'native-test','owner'=>'Alice'}
service.define_singleton_method(:open_match){|match_id:,leg:|calls << [match_id,leg]; table}
app.define_singleton_method(:ordinary_tournament_service){|_|service}
app.define_singleton_method(:run_network_task){|*_,**_,&operation|operation.call}
app.define_singleton_method(:activate_table_transport){|row|calls << [:activate,row]}
app.define_singleton_method(:show_table_screen){|row|calls << [:show,row]}
app.open_ordinary_tournament_match({'title'=>'Turniej'},{'match_id'=>'match-2','leg'=>2})
assert_equal([['match-2',2],[:activate,table],[:show,table]],calls)
puts 'PASS application tournament entry: public callbacks, selected match/leg, same ordinary table activation and screen'
