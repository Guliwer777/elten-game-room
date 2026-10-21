require_relative '../support/tournament_control_callbacks'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/server_schedule_overview'
require_relative '../../lib/tournaments/interrupted_outcome'
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})

scored={'status'=>'scored','kind'=>'deal','index'=>1,'event_id'=>42,'order'=>'higher',
  'scores'=>{'alpha'=>40,'beta'=>20,'gamma'=>60}}
[
  [false,{'status'=>'unsupported'},'The match had not started. The remaining participants share first place.'],
  [true,{'status'=>'none'},'No round was completed. The remaining participants share first place.'],
  [true,scored,'Places are based on the scores after the last completed deal.'],
  [true,scored.merge('kind'=>'round'),'Places are based on the scores after the last completed round.']
].each do |started,checkpoint,explanation|
  program=TournamentEntryContextTest::Program.new
  preview=T::InterruptedOutcome.build(units:%w[alpha beta gamma],loser:'gamma',started:started,
    checkpoint:checkpoint,continuation:{'status'=>'cannot_continue'},event_count:42)
  driver=TournamentControlCallbacks.new
  driver.step('Forfeit consequences') do |form|
    assert(form.fields.first.text.include?(explanation),'Native confirmation omitted the basis of places')
    form.cancel_button.press
  end
  T::ServerForfeitScreen::Confirmation.new(program:program,preview:preview).run
  driver.finish
  workspace=Object.new
  workspace.define_singleton_method(:actor) {'alpha'}
  match={'match_id'=>'m','number'=>1,'leg'=>1,'players'=>%w[alpha beta gamma]}
  receipt=preview.merge('kind'=>'ordinary-match-forfeit-v2','organizer'=>'alpha',**match.slice('match_id','leg'))
  candidate={'format'=>'round_robin','schedule_id'=>'current','matches'=>[match]}
  view={'results'=>[receipt],'standings'=>[], 'forfeit_conflicts'=>[match.slice('match_id','leg')],
    'forfeit_unavailable_matches'=>[{'match_id'=>'unavailable','leg'=>1}]}
  program.define_singleton_method(:ordinary_tournament_overview) { |*_,**| {'candidate'=>candidate,'storage'=>'confirmed','results'=>view} }
  owner=T::Dialogs::Owner.new(-> {'alpha'},->(message) {raise message})
  screen=T::ServerScheduleOverview.new(program:program,workspace:workspace,owner:owner,
    publication:{'title'=>'Explanation','__insertion_user'=>'alpha','publication_key'=>'explanation'})
  driver=TournamentControlCallbacks.new
  driver.step('Tournament matches') do |form|
    details=form.fields.find { |field| field.is_a?(EditBox) }
    assert(details.text.include?('Conflicting match results were recorded.'),'Conflicting complete receipts were not visible')
    assert(details.text.include?('Join the table as an observer'),'Unavailable native history lacked an explanation')
    form.fields.first.index=1
    actions={}
    menu=Object.new
    menu.define_singleton_method(:option) { |label,*_,&block| actions[label]=block }
    form.fields.first.context(menu,false)
    actions.fetch('Result details').call
  end
  driver.step('Result details') do |form|
    assert(form.fields.first.text.include?(explanation),'Result details differed from the confirmed basis of places')
    form.cancel_button.press
  end
  driver.step('Tournament matches') { |form| form.cancel_button.press }
  screen.run
  driver.finish
ensure
  program&.finalize
  program&.class&.app_runtime&.close
end
puts 'PASS native forfeit explanations: shared before-start/no-round/deal/round basis in confirmation and result details; visible conflict and unavailable-history diagnostics'
