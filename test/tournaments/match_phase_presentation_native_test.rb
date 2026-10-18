require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/server_schedule_overview'
require_relative '../../lib/tournaments/knockout_round'
include GameRoomTest::Assertions
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
screen=T::ServerScheduleOverview.allocate
cases={2=>'Final',3=>'Semifinals',4=>'Semifinals',5=>'Quarterfinals',8=>'Quarterfinals',9=>'Round of 16',16=>'Round of 16',32=>'Knockout round: 1'}
cases.each do |count,label|
  plan=T::KnockoutRound.build(seeds:Array.new(count){|i|"player#{i}"},players_per_match:2,round_number:1)
  candidate={'format'=>'knockout','knockout'=>plan}
  before=JSON.generate(candidate)
  assert_equal(label,screen.send(:phase_label,candidate),"Wrong name for #{count} participants, including byes")
  assert_equal(before,JSON.generate(candidate),'Presentation modified the bracket')
end
assert_equal('Group stage',screen.send(:phase_label,{'format'=>'groups_knockout'}))
assert_equal('Round robin',screen.send(:phase_label,{'format'=>'round_robin'}))
assert_equal('Knockout round: 2',screen.send(:phase_label,{'format'=>'knockout','knockout'=>
  T::KnockoutRound.build(seeds:%w[a b c],players_per_match:3,round_number:2)}))
team_final={'format'=>'knockout','roster'=>%w[a b c d],'knockout'=>{'round'=>3,'players_per_match'=>2,'seeds'=>%w[team1 team2]}}
assert_equal('Final',screen.send(:phase_label,team_final),'Teams were counted as individual players')
%w[replay series rematch].each do |kind|
  candidate={'format'=>'knockout','matches'=>[{'players'=>%w[a b]}],
    'knockout'=>{'round'=>2,'players_per_match'=>2,'seeds'=>%w[a b c d],kind=>true}}
  assert_equal('Semifinals',screen.send(:phase_label,candidate),"Partial #{kind} was mistaken for a final")
end
qualifier={'format'=>'knockout','knockout'=>{'round'=>1,'players_per_match'=>2,'seeds'=>%w[a b],'qualification'=>{}}}
assert_equal('Additional matches to resolve group qualification',screen.send(:phase_label,qualifier))

{'en'=>['Quarterfinals','Semifinals','Round of 16'], 'pl'=>['Ćwierćfinały','Półfinały','1/8 finału'],
 'cs'=>['Čtvrtfinále','Semifinále','Osmifinále'], 'es'=>['Cuartos de final','Semifinales','Octavos de final'],
 'ru'=>['Четвертьфиналы','Полуфиналы','1/8 финала']}.each do |language,labels|
  GameRoomLocalization.boot(settings:{'interface_language'=>language,'known_languages'=>[language]})
  [8,4,16].zip(labels).each do |count,label|
    assert_equal(label,screen.send(:phase_label,{'format'=>'knockout','knockout'=>{'players_per_match'=>2,'seeds'=>Array.new(count)}}))
  end
end
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})

fixture=TournamentIndividualUI.fixture
program=fixture[:program]
revision=0
program.class.define_singleton_method(:tournament_view_revision){|*|revision}
workspace=Object.new
workspace.define_singleton_method(:actor){'alpha'}
candidate={'format'=>'knockout','schedule_id'=>'quarterfinal','matches'=>[
  {'match_id'=>'a'*64,'leg'=>1,'number'=>1,'players'=>%w[alpha beta]}],
  'knockout'=>{'round'=>1,'players_per_match'=>2,'seeds'=>%w[alpha beta gamma delta epsilon zeta eta theta]}}
history=[]
program.define_singleton_method(:ordinary_tournament_overview) do |*_,**|
  {'candidate'=>candidate,'phase_history'=>history,'storage'=>'confirmed','results'=>{'schedule_id'=>candidate['schedule_id'],'results'=>[],'standings'=>[]}}
end
owner=T::Dialogs::Owner.new(-> {TournamentIndividualUI::F::OWNER},->(message){raise message})
begin
  driver=TournamentNativeDriver.new
  driver.step('Tournament matches') do |form|
    assert_equal('Matches — Quarterfinals; completed: 0/1',form.fields.first.options.first)
    history << {'candidate'=>candidate,'view'=>{'results'=>[],'standings'=>[]}}
    candidate=candidate.merge('schedule_id'=>'semifinal','knockout'=>{'round'=>2,'players_per_match'=>2,'seeds'=>%w[alpha beta gamma delta]})
    SpeechOutput.reset
    revision+=1
  end
  driver.step('Tournament matches') do |form|
    assert_equal('Matches — Semifinals; completed: 0/1',form.fields.first.options.first)
    assert_equal([],SpeechOutput.calls,'Changing the phase header spoke over the user')
    assert_equal(0,form.fields.first.index)
    phases=TournamentIndividualUI::F.field(form,'Tournament phase')
    assert_equal(1,phases.index,'Current-phase selection did not follow automatic progression')
    phases.index=0
    phases.trigger(:move)
  end
  driver.step('Tournament matches') do |form|
    assert_equal('Matches — Quarterfinals; completed: 0/1',form.fields.first.options.first)
    history << {'candidate'=>candidate,'view'=>{'results'=>[],'standings'=>[]}}
    candidate=candidate.merge('schedule_id'=>'final','knockout'=>{'round'=>3,'players_per_match'=>2,'seeds'=>%w[alpha beta]})
    revision+=1
  end
  driver.step('Tournament matches',[27]) do |form|
    assert_equal(0,TournamentIndividualUI::F.field(form,'Tournament phase').index,'Refresh interrupted browsing an earlier phase')
    assert_equal('Matches — Quarterfinals; completed: 0/1',form.fields.first.options.first)
  end
  T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,
    publication:{'title'=>'Phase names','__insertion_user'=>TournamentIndividualUI::F::OWNER,'publication_key'=>'phase-names'}).run
  driver.finish
  driver=TournamentNativeDriver.new
  driver.step('Tournament matches',[27]) do |form|
    assert_equal(2,TournamentIndividualUI::F.field(form,'Tournament phase').index,'Reopening did not select the latest phase')
    assert_equal('Matches — Final; completed: 0/1',form.fields.first.options.first)
  end
  T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,
    publication:{'title'=>'Phase names','__insertion_user'=>TournamentIndividualUI::F::OWNER,'publication_key'=>'phase-names'}).run
  driver.finish
ensure
  program.class.singleton_class.remove_method(:tournament_view_revision)
  program.finalize
  program.class.app_runtime.close
end
puts 'PASS phase presentation: bracket size, byes, teams, replays, qualifiers, five languages and silent native refresh'
