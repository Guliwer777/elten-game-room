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
action=cancel_started ? 'Cancel tournament match and award forfeit' : 'Award forfeit'
calls=[]
fixture[:program].define_singleton_method(:ordinary_tournament_results) do |_|
  {'schedule_id'=>candidate['schedule_id'],'standings'=>[],'forfeitable_matches'=>awarded || cancel_started ? [] : [match.slice('match_id','leg')],
    'cancellable_matches'=>!awarded && cancel_started ? [match.slice('match_id','leg')] : [],
    'results'=>awarded ? [{'kind'=>cancel_started ? 'ordinary-match-cancel-forfeit-v1' : 'ordinary-match-forfeit-v1','match_id'=>match['match_id'],'leg'=>1,
      'summary'=>{'participants'=>match['players'],'winners'=>['second'],'draw'=>false,'scores'=>nil}}] : []}
end
fixture[:program].define_singleton_method(:award_ordinary_tournament_forfeit) do |*args|
  calls << args
  awarded=true
end
driver=TournamentNativeDriver.new
driver.step('Matches, groups and standings',[13]) do |form|
  field=F.button(form,action)
  assert(form.instance_variable_get(:@hidden)[form.fields.index(field)]!=true,'Organizer forfeit action hidden before result')
  form.index=form.fields.index(field)
end
driver.step(cancel_started ? 'Cancelling the tournament match' : 'Winner by forfeit',[13]) do |form|
  form.fields.find{|field|field.is_a?(ListBox)}.index=1
  form.index=form.fields.index(F.button(form,'Confirm forfeit: 2 points to winner, 0 to loser, no small points'))
end
driver.step('Matches, groups and standings',[27]) do |form|
  assert(form.instance_variable_get(:@hidden)[form.fields.index(F.button(form,action))]==true,'Forfeit action remained visible after result')
  assert(form.fields.first.text.include?('Forfeit'),'Result does not identify a forfeit')
end
control=GameRoomTournaments::LocalTestDialogs::Owner.new(-> {F::OWNER},->(message){raise message})
GameRoomTournaments::ServerScheduleOverview.new(program:fixture[:program],workspace:workspace,owner:control,
  publication:{'title'=>'Forfeit controls','__insertion_user'=>F::OWNER,'publication_key'=>'fixture'}).run
driver.finish
assert_equal(1,calls.size)
assert_equal('second',calls.first[2])
assert_equal(candidate['schedule_id'],calls.first[3])
fixture[:program].finalize
fixture[:program].class.app_runtime.close
puts 'PASS native forfeit controls: selected winner and displayed phase, action disappears after result'
