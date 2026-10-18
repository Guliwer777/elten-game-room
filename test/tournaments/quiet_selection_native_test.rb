require_relative '../support/tournament_individual_ui'
require_relative '../support/tournament_public_ui'
require_relative '../support/tournament_window_fields'
require_relative '../../lib/tournaments/server_schedule_overview'
require_relative '../../lib/tournaments/public_screen'
require_relative '../../lib/tournaments/tournament_dates_editor'
require File.join(EltenTestHost.root,'src/ui/controls/static')
Object.const_set(:Static,EltenAPI::Controls.const_get(:Static)) unless Object.const_defined?(:Static)
include GameRoomTest::Assertions

T=GameRoomTournaments
F=TournamentIndividualUI::F
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})

def one_selection_announcement(control)
  messages=SpeechOutput.calls.map{|call|call.first.to_s}
  assert_equal([control.options[control.index]],messages,'Selection repeated the whole control instead of announcing just the new item')
end

fixture=TournamentIndividualUI.fixture
program=fixture[:program]
revision=0
program.class.define_singleton_method(:tournament_view_revision){|*|revision}
matches=[
  {'match_id'=>'a'*64,'number'=>1,'leg'=>1,'players'=>%w[alpha beta]},
  {'match_id'=>'b'*64,'number'=>2,'leg'=>1,'players'=>%w[alpha gamma]},
  {'match_id'=>'c'*64,'number'=>3,'leg'=>1,'players'=>%w[beta gamma]}
]
completed=[{'match_id'=>'a'*64,'leg'=>1,'summary'=>{'draw'=>true,'winners'=>[]}}]
program.define_singleton_method(:open_ordinary_tournament_match){|*|raise 'Navigation opened a table'}
program.define_singleton_method(:ordinary_tournament_overview) do |_,workspace:,**|
  workspace.shared_schedule.merge('results'=>{'results'=>completed,'standings'=>[]})
end
actor='alpha'
workspace=Object.new
workspace.define_singleton_method(:actor){actor}
workspace.define_singleton_method(:shared_schedule) do |**|
  {'storage'=>'confirmed','candidate'=>{'format'=>'round_robin','schedule_id'=>'schedule','matches'=>matches}}
end
owner=T::Dialogs::Owner.new(-> {F::OWNER},->(message){raise message})
publication={'title'=>'Selection test','__insertion_user'=>F::OWNER,'publication_key'=>'selection-test'}

begin
  driver=TournamentNativeDriver.new
  driver.step('Tournament matches',[13]) do |form|
    assert_equal(0,form.fields.first.index,'The phase summary was not selected on entry')
    assert_equal('Matches — Round robin; completed: 1/3',form.fields.first.options.first)
    assert(!form.fields.any?{|field|field.respond_to?(:header) && ['Match status','Show matches'].include?(field.header)},'Redundant match filter remains')
    assert_equal(['alpha — gamma; To be played','beta — gamma; To be played','alpha — beta; Draw'],form.fields.first.options.drop(1))
    menu=Object.new
    menu.define_singleton_method(:option){|*|raise 'Summary exposes a match action'}
    form.fields.first.context(menu,false)
  end
  driver.step('Tournament matches',[38]) do |form|
    # Exercise a normal arrow, not a direct call to the move handler.
    form.fields.first.index=2
    SpeechOutput.reset
  end
  driver.step('Tournament matches') do |form|
    one_selection_announcement(form.fields.first)
    form.fields.first.index=1
    SpeechOutput.reset
    completed << {'match_id'=>'b'*64,'leg'=>1,'summary'=>{'draw'=>true,'winners'=>[]}}
    revision+=1
  end
  driver.step('Tournament matches',[9]) do |form|
    assert_equal([],SpeechOutput.calls,'An event-driven refresh spoke the list')
    assert_equal('Matches — Round robin; completed: 2/3',form.fields.first.options.first)
    assert_equal(3,form.fields.first.index,'Refresh moved to a different match')
    assert_equal('alpha — gamma; Draw',form.fields.first.options[3])
  end
  driver.step('Tournament matches',[27]) do |form|
    assert_equal(F.field(form,'Tournament phase'),form.fields[form.index],'Tab did not move directly to the phase selector')
    assert_equal(['beta — gamma; To be played','alpha — beta; Draw','alpha — gamma; Draw'],form.fields.first.options.drop(1),'Unfinished matches must precede completed ones')
    assert_equal('alpha — gamma; Draw',form.fields.first.options[form.fields.first.index],'Tab moved to another match')
  end
  T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,publication:publication).run
  driver.finish

  actor='spectator'
  driver=TournamentNativeDriver.new
  driver.step('Tournament matches',[27]) do |form|
    assert_equal(4,form.fields.first.options.size)
    assert_equal('beta — gamma; To be played',form.fields.first.options[1],'A spectator did not see the unfinished match below the summary')
  end
  T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,publication:publication).run
  driver.finish

  snapshot=TournamentPublicUI.snapshot
  driver=TournamentNativeDriver.new
  driver.press('Tournaments',9)
  driver.step('Tournaments',[39]){SpeechOutput.reset}
  driver.step('Tournaments',[27]){|form|one_selection_announcement(F.field(form,'Show tournaments'))}
  args=TournamentPublicUI.arguments(snapshot,program:program).reject{|key,_|[:publication,:snapshot].include?(key)}
  T::PublicScreen.new(**args).run
  driver.finish

  snapshot=TournamentPublicUI.snapshot([TournamentPublicUI.publication],[TournamentPublicUI.registration(1)])
  moving=TournamentPublicUI.snapshot([TournamentPublicUI.publication(11),TournamentPublicUI.publication(22)])
  driver=TournamentNativeDriver.new
  driver.step('Tournaments') do |form|
    form.fields.first.index=1
    SpeechOutput.reset
    moving=TournamentPublicUI.snapshot([TournamentPublicUI.publication(11),TournamentPublicUI.publication(22)],
      [TournamentPublicUI.registration(99,tournament_id:22)])
    revision+=1
  end
  driver.step('Tournaments',[27]) do |form|
    assert_equal([],SpeechOutput.calls,'Priority reorder spoke the refreshed list')
    assert_equal(0,form.fields.first.index,'Selection did not follow the joined tournament')
    assert(form.fields.first.options.first.start_with?('Próba 22'),'Priority reorder selected a different tournament')
  end
  args=TournamentPublicUI.arguments(moving,program:program,load:-> {moving},clock:-> {150}).reject{|key,_|[:publication,:snapshot].include?(key)}
  T::PublicScreen.new(**args).run
  driver.finish

  opened=[]
  driver=TournamentNativeDriver.new
  driver.step(/\APróba 11 — Łódź — /,[13]) do |form|
    actions=form.fields.first
    assert_equal(actions,form.fields[form.index],'Entry did not focus the actions')
    assert_equal(1,actions.options.count('Tournament matches'),'The match entry is missing or duplicated')
    assert(!actions.options.include?('My match'),'Redundant My match remains')
    form.index=form.fields.index(actions)
    actions.index=actions.options.index('Tournament matches')
  end
  driver.step(/\APróba 11 — Łódź — /) do |form|
    assert_equal(1,opened.size,'Matches did not open the shared schedule')
    actions=form.fields.first
    actions.index=actions.options.index('Information and rules')
    SpeechOutput.reset
    revision+=1
  end
  driver.step(/\APróba 11 — Łódź — /,[27]) do |form|
    assert_equal([],SpeechOutput.calls,'A dashboard refresh announced the actions again')
    actions=form.fields.first
    assert_equal('Information and rules',actions.options[actions.index])
    assert_equal(actions,form.fields[form.index])
  end
  T::PublicPreview.new(**TournamentPublicUI.arguments(snapshot,program:program,overview:->(row){opened<<row},
    clock:-> {Time.utc(2026,10,15,19).to_i})).wait
  driver.finish

  driver=TournamentNativeDriver.new
  driver.press('Dates and playing hours',9)
  driver.step('Dates and playing hours',[39]){SpeechOutput.reset}
  driver.step('Dates and playing hours') do |form|
    one_selection_announcement(F.field(form,'Open registration'))
    checkbox=form.fields.grep(CheckBox).find{|field|field.label=='Schedule the close of registration'}
    assert(checkbox,'Missing scheduling checkbox')
    form.index=form.fields.index(checkbox)
  end
  driver.step('Dates and playing hours',[32]){SpeechOutput.reset}
  driver.step('Dates and playing hours',[27]) do
    assert_equal(1,SpeechOutput.calls.size,'A checkbox change repeated its full label')
  end
  T::TournamentDatesEditor.new(program:program,values:T::TournamentDatesEditor.values(nil),
    alert:->(message){raise message},clock:-> {Time.utc(2026,10,15,12).to_i}).run
  driver.finish
  puts 'PASS native tournament selection: one item announcement, silent event refresh, stable match and ordinary checkboxes'
ensure
  program.class.singleton_class.remove_method(:tournament_view_revision)
  program.finalize
  program.class.app_runtime.close
end
