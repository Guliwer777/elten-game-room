if ARGV.first
  previous=ENV['ELTEN_TEST_NATIVE_CONTROLS']
  begin
    ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
    require_relative '../support/binary_rules_load'
  ensure
    ENV['ELTEN_TEST_NATIVE_CONTROLS']=previous
  end
end
require_relative '../support/tournament_individual_ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/tournaments/public_screen'
include GameRoomTest::Assertions
class VirtualContextMenu
  attr_reader :actions
  def initialize;@actions={};end
  def option(label,*_args,&action);@actions[label]=action;end
end
fixture=TournamentIndividualUI.fixture
u=TournamentPublicUI
GameRoomLocalization.boot(settings:{'interface_language'=>'pl','known_languages'=>['pl']})
l=->(text){GameRoomContent.utf8(GameRoomLocalization.translate(text))}
now=Time.utc(2026,10,13,12).to_i
row=u.publication(11).merge('__insertion_user'=>u::ACTOR,'timezone'=>'UTC',
  'registration_opens_at'=>now-100,'registration_closes_at'=>now+100)
snapshot=u.snapshot([row],[])
calls,alerts=[],[]
args=u.arguments(snapshot,load:-> {snapshot},join:->(*){raise 'Real-account join used for virtual player'},
  alert:->(message){alerts<<message}).reject{|key,_|[:publication,:snapshot].include?(key)}
args.merge!(program:fixture[:program],clock:-> {now},join_virtual:->(id,name){calls<<[id,name];u.record('attempted',tournament_id:id)})
header=l.call('Ongoing tournaments')
driver=TournamentNativeDriver.new
driver.step(header,[]) do |form|
  form.index=1
  menu=VirtualContextMenu.new
  form.fields[1].context(menu,false)
  menu.actions.fetch(l.call('Join tournament')).call
end
driver.step(l.call('Virtual player name (local test only)'),[]) do |form|
  assert_equal(3,form.fields.size,'Virtual join opened the full details browser')
  form.fields[1].trigger(:press)
  assert_equal([],calls,'Empty name wrote registration')
  form.fields[0].set_text('benek')
  form.fields[1].trigger(:press)
end
driver.step(header,[27]) do |form|
  assert_equal(1,form.index,'Virtual input did not return focus to the tournament list')
  assert_equal([[11,'benek']],calls,'Uncertain registration was repeated')
  assert_equal(2,driver.forms.size,'Virtual registration opened unexpected details')
  assert(alerts.include?(l.call('Enter a virtual player name.')),'Blank name validation was not announced')
end
begin
  GameRoomTournaments::PublicScreen.new(**args).run
  driver.finish
  assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native virtual context join: minimal name modal, blank rejected, single uncertain write, focused list return, clean resources'
