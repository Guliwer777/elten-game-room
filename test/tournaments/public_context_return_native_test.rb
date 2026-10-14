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
class ReturnContextMenu
  attr_reader :actions
  def initialize;@actions={};end
  def option(label,*_args,&action);@actions[label]=action;end
end
u=TournamentPublicUI
fixture=TournamentIndividualUI.fixture
GameRoomLocalization.boot(settings:{'interface_language'=>'pl','known_languages'=>['pl']})
l=->(text){GameRoomContent.utf8(GameRoomLocalization.translate(text))}
now=Time.utc(2026,10,13,12).to_i
row=u.publication(11).merge('__insertion_user'=>u::ACTOR,'timezone'=>'UTC',
  'registration_opens_at'=>now-100,'registration_closes_at'=>now+100)
registrations=[]
snapshot=u.snapshot([row],registrations)
calls=[]
args=u.arguments(snapshot,load:-> {snapshot},join:->(id){calls<<:join;registrations<<u.registration(77,tournament_id:id,time:now);snapshot=u.snapshot([row],registrations);u.record('confirmed',tournament_id:id)},
  alert:->(_message){}).reject{|key,_|[:publication,:snapshot].include?(key)}
args[:program]=fixture[:program]
args.merge!(clock:-> {now},withdraw:->(id){calls<<:withdraw;registrations<<u.registration(78,tournament_id:id,time:now).merge('kind'=>'withdrawal');snapshot=u.snapshot([row],registrations);u.record('confirmed',tournament_id:id)},
  edit_tournament:->(_row){calls<<:edit},manage_participants:->(_row){calls<<:manage},overview:->(_row){calls<<:overview},
  delete_tournament:->(_row){calls<<:delete;snapshot=u.snapshot([],[])})
header=l.call('Ongoing tournaments')
driver=TournamentNativeDriver.new
driver.step(header,[]) do |form|
  form.index=1
  list=form.fields[1]
  %w[Join\ tournament Leave\ tournament Edit\ tournament Manage\ participants Matches,\ groups\ and\ standings].each do |label|
    menu=ReturnContextMenu.new
    list.context(menu,false)
    menu.actions.fetch(l.call(label)).call
    assert_equal(1,driver.forms.size,'A context action opened tournament details')
    assert_equal(1,form.index,'A context action moved focus away from its tournament list')
    assert_equal([11],list.instance_variable_get(:@item_keys))
  end
  menu=ReturnContextMenu.new
  list.context(menu,false)
  menu.actions.fetch(l.call('View tournament')).call
end
driver.step(l.call('Tournament details'),[27]){}
driver.step(header,[27]) do |form|
  assert_equal(2,driver.forms.size,'Explicit View did not open exactly one details form')
  menu=ReturnContextMenu.new
  form.fields[1].context(menu,false)
  menu.actions.fetch(l.call('Delete tournament')).call
  assert_equal([],form.fields[1].instance_variable_get(:@item_keys))
  assert_equal(2,driver.forms.size,'Delete opened details after deleting the selected tournament')
end
begin
  GameRoomTournaments::PublicScreen.new(**args).run
  driver.finish
  assert_equal(%i[join withdraw edit manage overview delete],calls)
  assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native context actions: join/withdraw/edit/manage/results/delete return to the focused list; only explicit View opens details; clean resources'
