if ARGV.first
  ENV['ELTEN_TEST_NATIVE_CONTROLS']='1'
  require_relative '../support/binary_rules_load'
end
require_relative '../support/tournament_native'
require_relative '../support/tournament_entry_context'
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
driver=TournamentNativeDriver.new
driver.step(nil,[27]) do |form|
  assert_equal(['Tournament list','Create tournament','Back'],form.fields.map(&:label))
  menu=Object.new
  labels=[]
  menu.define_singleton_method(:option){|label,*_,&block|labels << label}
  form.fields.first.context(menu,false)
  assert(labels.include?('Operations'),'Necessary recovery menu removed')
end
GameRoomTournaments::Hub.new(program:program,registry:GameRoomGames::CATALOG,user:-> {'Alice'},alert:->(message){raise message},
  confirm:->(_){true},workspace_factory:-> {workspace}).run
driver.finish
program.managed_resources.close
program.class.app_runtime.close
puts 'PASS production hub: list/create/back only, no fake players or trial menus, recovery retained in context'
