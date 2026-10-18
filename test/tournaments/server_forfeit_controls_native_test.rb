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
owner=F::OWNER.downcase
match={'match_id'=>'b'*64,'number'=>1,'leg'=>1,'players'=>[owner,'second']}
candidate={'format'=>'round_robin','schedule_id'=>'a'*64,'matches'=>[match]}
workspace=Object.new
workspace.define_singleton_method(:actor){F::OWNER}
workspace.define_singleton_method(:shared_proposal){}
workspace.define_singleton_method(:shared_schedule){|**|{'storage'=>'confirmed','candidate'=>candidate}}
awarded=false
cancel_started=ENV['TEST_CANCEL']=='1'
action='Award forfeit'
calls=[]
fixture[:program].define_singleton_method(:ordinary_tournament_overview) do |_,workspace:,**|
  workspace.shared_schedule.merge('results'=>{'schedule_id'=>candidate['schedule_id'],'standings'=>[],'forfeitable_matches'=>awarded || cancel_started ? [] : [match.slice('match_id','leg')],
    'cancellable_matches'=>!awarded && cancel_started ? [match.slice('match_id','leg')] : [],
    'results'=>awarded ? [{'kind'=>cancel_started ? 'ordinary-match-cancel-forfeit-v1' : 'ordinary-match-forfeit-v1','match_id'=>match['match_id'],'leg'=>1,
      'summary'=>{'participants'=>match['players'],'winners'=>['second'],'draw'=>false,'scores'=>nil}}] : []})
end
fixture[:program].define_singleton_method(:award_ordinary_tournament_forfeit) do |*args,**_options|
  calls << args
  awarded=true
end
driver=TournamentNativeDriver.new
driver.step('Tournament matches') do |form|
  form.fields.first.index=1
  assert(!form.fields.grep(Button).any?{|field|field.label==action},'Forfeit remains an extra Tab stop')
  menu=Object.new
  actions={}
  menu.define_singleton_method(:option){|label,*_,&block|actions[label]=block}
  form.fields.first.context(menu,false)
  actions.fetch(action).call
end
driver.step('Who loses by forfeit?',[13]) do |form|
  form.fields.find{|field|field.is_a?(ListBox)}.index=0
  form.index=form.fields.index(F.button(form,'Next'))
end
driver.step('Tournament matches',[27]) do |form|
  assert_equal('Matches — Round robin; completed: 1/1',form.fields.first.options.first)
  assert_equal(2,form.fields.first.options.size,'Completed match or summary missing')
  assert_equal(1,form.fields.first.index,'Completion moved selection from the match')
  assert(form.fields.first.options.join.include?('Forfeit'),'Result does not identify a forfeit')
  menu=Object.new
  actions={}
  menu.define_singleton_method(:option){|label,*_,&block|actions[label]=block}
  form.fields.first.context(menu,false)
  assert(!actions.key?(action),'Completed result still exposes forfeit')
end
control=GameRoomTournaments::LocalTestDialogs::Owner.new(-> {F::OWNER},->(message){raise message})
GameRoomTournaments::ServerScheduleOverview.new(program:fixture[:program],workspace:workspace,owner:control,
  publication:{'title'=>'Forfeit controls','__insertion_user'=>F::OWNER,'publication_key'=>'fixture'}).run
driver.finish
assert_equal(1,calls.size)
assert_equal(owner,calls.first[2])
assert_equal(candidate['schedule_id'],calls.first[3])
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native forfeit controls: one selected losing-unit action for both started/unstarted matches and the action disappears after result'
