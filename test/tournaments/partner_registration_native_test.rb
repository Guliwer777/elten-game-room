require_relative '../support/tournament_individual_ui'
require_relative '../../lib/tournaments/public_preview'
include GameRoomTest::Assertions
I=TournamentIndividualUI
F=I::F
T=GameRoomTournaments
GameRoomLocalization.boot(settings:{'interface_language'=>'pl','known_languages'=>['pl']})
label=->(s){GameRoomContent.utf8(GameRoomLocalization.translate(s))}
state=I.fixture(names:%w[Alpha Beta Gamma Delta],game:'spades',game_options:{'team_size'=>2},players_per_match:4)
state[:now]=150
factory=->(actor){T::LocalWorkspace.new(program:state[:program],registry:GameRoomGames::CATALOG,user:-> {F::OWNER},
  actor:actor,alert:->(m){raise m},clock:-> {state[:now]})}
[%w[Alpha Beta],%w[Beta Alpha]].each_with_index do |(actor,partner),index|
  workspace=factory.call(actor)
  snapshot=workspace.load
  driver=TournamentNativeDriver.new
  driver.step(/\AIndividual UI — /,[13]) do |form|
    actions=form.fields.first
    actions.index=actions.options.index(label.call('Team partner'))
    form.index=form.fields.index(actions)
  end
  driver.step(label.call('Team'),[13]) do |form|
    list=F.field(form,label.call('Partner'))
    desired=index.zero? ? partner : label.call('Confirm partnership with %{player}')%{player:partner}
    list.index=list.options.index(desired)
    assert(list.index,'Reciprocal partner choice missing')
    form.index=form.fields.index(list)
  end
  driver.step(/\AIndividual UI — /,[27])
  T::PublicPreview.new(program:state[:program],registry:GameRoomGames::CATALOG,publication:snapshot['announcements'].first,
    snapshot:snapshot,load:workspace.method(:load),join:workspace.method(:join),actor:workspace.actor,mode_label:workspace.mode_label,
    clock:-> {150},set_partner:->(id,who,other,intent){factory.call(who).set_partner(id,who,other,intent)},alert:->(*){}).wait
  driver.finish
  result=workspace.load
  assert_equal(index.zero? ? [] : [%w[alpha beta]],result['pairs'].map{|pair|pair['accounts']})
  assert(result['pair_requests'].any?{|request|request['from']=='alpha' && request['to']=='beta'},'Pending partner request missing') if index.zero?
end
state[:program].finalize
state[:program].class.app_runtime.close
puts 'PASS native Polish partner selection: one request is not consent, reciprocal selection confirms the team'
