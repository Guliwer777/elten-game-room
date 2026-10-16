require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/settings_widget'
require_relative '../support/assertions'
include GameRoomTest::Assertions
app=EltenGameRoom.new
%i[open_ordinary_tournament_match ordinary_tournament_overview reconcile_ordinary_tournament_operation].each do |name|
  assert(app.respond_to?(name), "Tournament window cannot call #{name}")
end
service=Object.new
calls=[]
table={'__id'=>7,'__live_session_id'=>'native-test','owner'=>'Alice'}
service.define_singleton_method(:open_match){|match_id:,leg:|calls << [match_id,leg]; table}
service.define_singleton_method(:invitation_players){|_|%w[Bob Carol]}
lobby=Object.new
lobby.define_singleton_method(:snapshot_for){|_|Struct.new(:members).new(%w[Alice Carol])}
app.instance_variable_set(:@lobby,lobby)
app.define_singleton_method(:deliver_table_invitation){|row,person|calls << [:invite,row,person]}
app.define_singleton_method(:ordinary_tournament_service){|_|service}
app.define_singleton_method(:run_network_task){|*_,**_,&operation|operation.call}
app.define_singleton_method(:activate_table_transport){|row|calls << [:activate,row]}
app.define_singleton_method(:show_table_screen){|row|calls << [:show,row]}
app.open_ordinary_tournament_match({'title'=>'Turniej','__insertion_user'=>'Alice','publication_key'=>'fixture-publication'},{'match_id'=>'match-2','leg'=>2})
assert_equal([['match-2',2],[:activate,table],[:invite,table,'Bob'],[:show,table]],calls)
workspace=Object.new
overview_calls=[]
workspace.define_singleton_method(:schedule_overview){|**args|overview_calls<<args; :overview}
publication={'__insertion_user'=>'Alice','publication_key'=>'fixture-publication'}
assert_equal(:overview,app.ordinary_tournament_overview(publication,workspace:workspace,context: :context,lease: :lease,match_controls:true))
app.ordinary_tournament_overview(publication,workspace:workspace,context: :context,lease: :lease,match_controls:false)
app.ordinary_tournament_overview(publication.merge('__insertion_user'=>'Bob'),workspace:workspace,context: :context,lease: :lease,match_controls:true)
assert_equal([true,false,false],overview_calls.map{|value|value[:include_match_status]})
assert(overview_calls.all?{|value|value[:context]==:context && value[:lease]==:lease},'Read-only overview lost its UI lease')
entry=EltenGameRoom.new
checked=0
attached=false
binding=Object.new
binding.define_singleton_method(:attached_table?){|_|attached}
binding.define_singleton_method(:attach_table){|_|checked+=1;attached=true}
entry.define_singleton_method(:ordinary_tournament_service){|_,worker:|raise 'Not a worker' unless worker;binding}
marked={'__id'=>9,'__live_session_id'=>'room','tournament_match'=>{'publication_ref'=>{'author'=>'Alice','publication_key'=>'fixture'},'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1}}
entry.send(:attach_tournament_table_on_worker,marked)
entry.send(:attach_tournament_table_on_worker,marked,presentation_only:true)
assert_equal(1,checked,'Displaying an already checked table repeated attachment')
entry.send(:attach_tournament_table_on_worker,marked)
assert_equal(2,checked,'Rejoining skipped fresh entry verification')
puts 'PASS application tournament entry: public callbacks, selected match/leg, same ordinary table activation and screen'
