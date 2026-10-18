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
require_relative '../support/tournament_context_native'
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
invitations=0
fixture[:program].define_singleton_method(:switch_to_invited_table){invitations+=1}
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
header=l.call('Tournaments')
driver=TournamentNativeDriver.new
driver.step(header,[]) do |form|
  form.index=0
  list=form.fields[0]
  items=TournamentNativeContext.items(form)
  labels=items.map(&:first)
  assert_equal(%w[Open\ tournament Join\ tournament Tournament\ matches Manage\ tournament Refresh Accept\ invitation].map(&l),labels)
  assert_equal('d',items[1].last,'Join conflicts with the global Ctrl+J invitation shortcut')
  assert_equal('j',items.last.last,'Invitation lost its Ctrl+J label')
  items.last[1].call
  assert_equal(1,invitations,'Reordered invitation lost its existing callback')
  form.index=1
  assert_equal([l.call('Accept invitation')],TournamentNativeContext.items(form).map(&:first),'Filter context lost or duplicated invitation')
  form.index=0
  %w[Join\ tournament Leave\ tournament Tournament\ matches].each do |label|
    menu=ReturnContextMenu.new
    list.context(menu,false)
    menu.actions.fetch(l.call(label)).call
    assert_equal(1,driver.forms.size,'A context action opened tournament details')
    assert_equal(0,form.index,'A context action moved focus away from its tournament list')
    assert_equal([11],list.instance_variable_get(:@item_keys))
  end
  2.times do
    menu=ReturnContextMenu.new
    list.context(menu,false)
    menu.actions.fetch(l.call('Manage tournament')).call
    assert_equal(0,form.index,'Management moved the directory selection')
    assert_equal([11],list.instance_variable_get(:@item_keys))
  end
  menu=ReturnContextMenu.new
  list.context(menu,false)
  menu.actions.fetch(l.call('Open tournament')).call
end
%w[Edit\ tournament Manage\ participants].each do |action|
  driver.step(l.call('Manage tournament'),[]) do |form|
    list=form.fields.first
    list.index=list.options.index(l.call(action))
    list.trigger(:select)
  end
end
driver.step(/\APróba 11 — Łódź — /,[27]){}
driver.step(header,[27]) do |form|
  assert_equal(4,driver.forms.size,'Explicit Open did not open exactly one tournament form')
  menu=ReturnContextMenu.new
  form.fields[0].context(menu,false)
  menu.actions.fetch(l.call('Manage tournament')).call
  assert_equal([],form.fields[0].instance_variable_get(:@item_keys))
  assert_equal(%w[Refresh Accept\ invitation].map(&l),TournamentNativeContext.items(form).map(&:first),'Empty list lost its general actions or duplicated invitation')
  assert_equal(5,driver.forms.size,'Delete opened tournament details after cancellation')
end
driver.step(l.call('Manage tournament'),[]) do |form|
  list=form.fields.first
  list.index=list.options.index(l.call('Cancel tournament'))
  list.trigger(:select)
end
begin
  GameRoomTournaments::PublicScreen.new(**args).run
  driver.finish
  assert_equal(%i[join withdraw overview edit manage delete],calls)
  assert_equal(0,fixture[:program].class.app_runtime.managed_resources.size)
ensure
  fixture[:program].finalize
  fixture[:program].class.app_runtime.close
end
puts 'PASS native context actions: join/withdraw/edit/manage/results/delete return to the focused list; only explicit View opens details; clean resources'
