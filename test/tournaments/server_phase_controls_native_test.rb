if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_individual_ui'
require EltenTestHost.file('src/ui/controls/menu.rb')
require_relative '../../lib/tournaments/server_schedule_overview'
include GameRoomTest::Assertions
I=TournamentIndividualUI
F=I::F
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
fixture=I.fixture
calls=[]
owner=F::OWNER.downcase
summary={'participants'=>[owner,'second'].sort,'winners'=>[owner],'draw'=>false,'scores'=>{owner=>7,'second'=>4}}
old={'format'=>'groups_knockout','schedule_id'=>'a'*64,'matches'=>[{'match_id'=>'b'*64,'number'=>1,'leg'=>1,'players'=>[owner,'second']}],
  'groups'=>[{'id'=>'group-1','units'=>[owner,'second'],'matches'=>['b'*64],'places'=>1}]}
current={'format'=>'knockout','schedule_id'=>'c'*64,'knockout'=>{'round'=>1},'matches'=>[{'match_id'=>'d'*64,'number'=>1,'leg'=>1,'players'=>[owner,'second']}]}
workspace=Object.new
workspace.define_singleton_method(:actor){F::OWNER}
workspace.define_singleton_method(:shared_schedule) do |**|
  value={'storage'=>'confirmed','candidate'=>current}
  value['phase_history']=[{'candidate'=>old,'view'=>{'results'=>[{'match_id'=>'b'*64,'leg'=>1,'summary'=>summary}],
    'standings'=>[{'unit'=>owner,'points'=>2,'group'=>'group-1','place'=>1,'played'=>1}]}}]
  value
end
workspace.define_singleton_method(:advance_phase) do |**values|
  calls << values
  {'candidate'=>current}
end
fixture[:program].define_singleton_method(:ordinary_tournament_overview) do |_,workspace:,**|
  workspace.shared_schedule.merge('results'=>{'schedule_id'=>current['schedule_id'],'results'=>[], 'standings'=>[], 'champion'=>owner})
end
driver=TournamentNativeDriver.new
driver.step('Results — Knockout round: 1',[38]) do |form|
  phases=F.field(form,'Tournament phase')
  assert_equal(1,phases.index,'Results did not open on the current phase')
  assert(F.field(form,'Information').text.include?("Tournament winner: #{owner}"),'Final winner missing')
  assert(!form.fields.any?{|f|f.is_a?(Button)&&f.label.include?('Prepare')},'Automatic progression leaked an extra player action')
  form.index=form.fields.index(phases)
end
driver.step('Results — Group stage',[27]) do |form|
  assert_equal(0,F.field(form,'Tournament phase').index,'Could not select the previous phase')
  assert_equal(["Group group-1; 1. #{owner}; points: 2; played: 1"],form.fields.first.options)
end
owner_control=GameRoomTournaments::LocalTestDialogs::Owner.new(-> {F::OWNER},->(message){raise message})
GameRoomTournaments::ServerScheduleOverview.new(program:fixture[:program],workspace:workspace,owner:owner_control,
  publication:{'title'=>'Phase controls','__insertion_user'=>F::OWNER,'publication_key'=>'fixture'},mode: :results).run
driver.finish
assert_equal([],calls,'Reading results must not request a new phase')
driver=TournamentNativeDriver.new
driver.step('Matches') do |form|
  phases=F.field(form,'Tournament phase')
  assert_equal(1,phases.index,'Matches did not open on the current phase')
  phases.index=0
  phases.trigger(:move)
end
driver.step('Matches') do |form|
  assert_equal(2,form.fields.first.options.size,'Historical summary or completed match missing')
  assert_equal('Matches — Group stage; completed: 1/1',form.fields.first.options.first)
  form.fields.first.index=1
  menu=EltenAPI::Controls.const_get(:Menu).new
  form.fields.first.context(menu,false)
  result=menu.items.find{|item|item[0]=='Match result'}
  assert(result,'Historical match has no result action')
  assert_equal('w',result[3],'Result has no Ctrl+W shortcut')
  result[1].call
end
driver.step('Match result',[27]) do |form|
  content=form.fields.first.text
  assert(content.include?("#{owner}: 7") && content.include?('second: 4'),'Historical game score missing')
end
driver.step('Matches',[27])
GameRoomTournaments::ServerScheduleOverview.new(program:fixture[:program],workspace:workspace,owner:owner_control,
  publication:{'title'=>'Phase controls','__insertion_user'=>F::OWNER,'publication_key'=>'fixture'}).run
driver.finish
assert_equal([],calls,'Reading historical matches wrote a phase')
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native phase results: current winner, previous group standings and scores, no redundant progression action or write'
