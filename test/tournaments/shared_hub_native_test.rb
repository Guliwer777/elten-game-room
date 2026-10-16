if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_native'
require_relative '../support/tournament_entry_context'
require_relative '../support/tournament_public_ui'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/hub'
require_relative '../support/assertions'
include GameRoomTest::Assertions
GameRoomLocalization.boot(settings:{'interface_language'=>'en','known_languages'=>['en']})
program=TournamentEntryContextTest::Program.new
workspace=Object.new
workspace.define_singleton_method(:actor){'Alice'}
workspace.define_singleton_method(:mode_label){'Shared tournaments'}
workspace.define_singleton_method(:operations){[]}
workspace.define_singleton_method(:reconcile){|_|raise 'Read-only recovery menu sent a write'}
workspace.define_singleton_method(:load){TournamentPublicUI.snapshot([])}
%i[join withdraw set_partner edit_tournament delete_tournament].each do |name|
  workspace.define_singleton_method(name){|*|raise "Unexpected mutation: #{name}"}
end
driver=TournamentNativeDriver.new
driver.step('Tournaments',[27]) do |form|
  assert_equal(['Tournaments','Show tournaments'],form.fields.grep(ListBox).map(&:header))
  menu=Object.new
  labels=[]
  menu.define_singleton_method(:option){|label,*_,&block|labels << label}
  form.fields.first.context(menu,false)
  assert(labels.include?('Check pending changes'),'Necessary recovery menu removed')
  assert(labels.include?('Create tournament'),'Creation is missing from the empty list')
end
GameRoomTournaments::Hub.new(program:program,registry:GameRoomGames::CATALOG,user:-> {'Alice'},alert:->(message){raise message},
  confirm:->(_){true},workspace_factory:-> {workspace}).run
driver.finish
program.managed_resources.close
program.class.app_runtime.close
puts 'PASS production hub: opens the directory directly, one list and filter, creation and recovery available on an empty list'
