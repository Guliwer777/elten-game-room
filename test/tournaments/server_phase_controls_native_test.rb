if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/server_schedule_overview'
include GameRoomTest::Assertions
I=TournamentIndividualUI
F=I::F
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
fixture=I.fixture
advanced=false
calls=[]
owner=F::OWNER.downcase
summary={'participants'=>[owner,'second'].sort,'winners'=>[owner],'draw'=>false,'scores'=>{owner=>7,'second'=>4}}
old={'format'=>'groups_knockout','schedule_id'=>'a'*64,'matches'=>[{'match_id'=>'b'*64,'number'=>1,'leg'=>1,'players'=>[owner,'second']}],
  'groups'=>[{'id'=>'group-1','units'=>[owner,'second'],'matches'=>['b'*64],'places'=>1}]}
current={'format'=>'knockout','schedule_id'=>'c'*64,'knockout'=>{'round'=>1},'matches'=>[{'match_id'=>'d'*64,'number'=>1,'leg'=>1,'players'=>[owner,'second']}]}
workspace=Object.new
workspace.define_singleton_method(:actor){F::OWNER}
workspace.define_singleton_method(:shared_schedule) do |**|
  value={'storage'=>'confirmed','candidate'=>advanced ? current : old}
  value['phase_history']=[{'candidate'=>old,'view'=>{'results'=>[{'match_id'=>'b'*64,'leg'=>1,'summary'=>summary}],
    'standings'=>[{'unit'=>owner,'points'=>2,'group'=>'group-1'}]}}] if advanced
  value
end
workspace.define_singleton_method(:advance_phase) do |**values|
  calls << values
  advanced=true
  {'candidate'=>current}
end
fixture[:program].define_singleton_method(:ordinary_tournament_results) do |_publication|
  {'schedule_id'=>advanced ? current['schedule_id'] : old['schedule_id'],'results'=>[], 'standings'=>[], 'champion'=>advanced ? owner : nil}
end
driver=TournamentNativeDriver.new
driver.step('Matches, groups and standings',[13]) do |form|
  button=F.button(form,'Prepare the next tournament phase')
  form.index=form.fields.index(button)
end
driver.step('Matches, groups and standings',[27]) do |form|
  details=form.fields.first.text
  assert(details.include?('Previous tournament phase results'),'Group history disappeared from native overview')
  assert(details.include?('group-1'),'Old group table missing')
  assert(details.include?("Tournament winner: #{owner}"),'Final winner missing from native overview')
  assert(details.include?("#{owner}: 7; second: 4") || details.include?("second: 4; #{owner}: 7"),'Old game scores missing')
  assert(details.index('tournament points')<details.index('Game score:'),'Match results precede tournament points')
  assert(!details.include?('Result: Winner:'),'Redundant Result prefix remains')
end
owner_control=GameRoomTournaments::LocalTestDialogs::Owner.new(-> {F::OWNER},->(message){raise message})
GameRoomTournaments::ServerScheduleOverview.new(program:fixture[:program],workspace:workspace,owner:owner_control,
  publication:{'title'=>'Phase controls','__insertion_user'=>F::OWNER,'publication_key'=>'fixture'}).run
driver.finish
assert_equal(1,calls.size)
assert_equal(old['schedule_id'],calls.first[:expected_schedule_id],'Advance callback used the new phase instead of the displayed phase')
assert_equal({'author'=>F::OWNER,'publication_key'=>'fixture'},calls.first[:publication_ref])
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native phase controls: explicit organizer action captures displayed phase, refresh shows retained group results and final champion'
