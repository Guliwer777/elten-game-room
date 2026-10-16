if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_native'
require_relative '../support/tournament_entry_context'
require File.join(EltenTestHost.root,'src/ui/controls/static')
Object.const_set(:Static,EltenAPI::Controls.const_get(:Static)) unless Object.const_defined?(:Static)
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/hub'
require_relative '../support/assertions'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings:{'interface_language'=>'pl','known_languages'=>['pl']})
label=->(value){GameRoomContent.utf8(GameRoomLocalization.translate(value))}
program=TournamentEntryContextTest::Program.new
require_relative '../support/tournament_public_ui'
workspace=Object.new
workspace.define_singleton_method(:actor){'Alice'}
workspace.define_singleton_method(:mode_label){'Shared tournaments'}
workspace.define_singleton_method(:load){TournamentPublicUI.snapshot([])}
%i[join withdraw set_partner operations reconcile].each{|name|workspace.define_singleton_method(name){|*|raise 'Unexpected mutation'}}
workspace.define_singleton_method(:publish){|**|raise 'Cancelled creation published tournament'}
driver=TournamentNativeDriver.new
driver.step(label.call('Tournaments'),[]) do |form|
  menu=Object.new
  menu.define_singleton_method(:option){|name,*_,&block|block.call if name==label.call('Create tournament')}
  form.fields.first.context(menu,false)
end
driver.step(label.call('Game'),[13]){|form|form.fields.first.index=GameRoomGames::CATALOG.ids.index('tic_tac_toe')}
driver.step(nil,[13]) do |form|
  assert_equal([label.call('Next'),label.call('Cancel')],form.fields.grep(Button).map(&:label))
  form.index=form.fields.index(form.accept_button)
end
driver.step(label.call('Tournament name'),[27]) do |form|
  returns=form.fields.find{|field|field.respond_to?(:header) && field.header==label.call('Return matches')}
  assert_equal(0,returns.index)
  assert(form.fields.none?{|field|field.respond_to?(:header) && field.header.to_s.include?('testowego')},'Test actor field remains')
  count=form.fields.find{|field|field.respond_to?(:header) && field.header==label.call('Participant limit (maximum 128)')}
  assert_equal('16',count.text)
end
driver.step(label.call('Tournaments'),[27]){|form|assert_equal(2,form.fields.grep(ListBox).size)}
GameRoomTournaments::Hub.new(program:program,registry:GameRoomGames::CATALOG,user:-> {'Alice'},alert:->(message){raise message},
  confirm:->(_){true},workspace_factory:-> {workspace}).run
driver.finish
program.finalize
program.class.app_runtime.close
puts 'PASS clean native Polish creation: game, Next, tournament rules, No returns, default limit16, no actor field, cancelled without write'
