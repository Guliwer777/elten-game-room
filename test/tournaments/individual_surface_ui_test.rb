require_relative '../support/tournament_individual_ui'
require File.join(EltenTestHost.root, 'src/ui/controls/grid_box')
Object.const_set(:GridBox, EltenAPI::Controls.const_get(:GridBox))
require_relative '../../lib/game_surfaces'
require_relative '../../lib/tournaments/local_game_choice_dialog'
include GameRoomTest::Assertions
T = GameRoomTournaments
program = TournamentEntryContextTest::Program.new
session = T::LocalReadinessSession.new
session.choose_actor('Alpha')
context = T::EntryContext.new(program: program, runtime: program.class.app_runtime,
  owner_reader: -> { 'Owner' }, actor: 'Alpha', account_events: session.actor_events)
lease = context.capture
spec = GameSurfaces::GridSpec.new(width: 2, height: 2, header: 'Own board', cells: [['A','B'],['C','D']], row_origin: :top)
driver = TournamentNativeDriver.new
driver.step('Own board', [13])
choice = T::MatchEntryScreen::GameChoice.new(program: program, spec: spec, guard: -> { context.current?(lease) }, context: context, lease: lease).run
assert_equal('grid', choice['kind'])
assert_equal('select', choice['action'])
assert_equal([0, 0], choice.values_at('x', 'y'))
driver.finish
driver = TournamentNativeDriver.new
driver.step('Own board', [13]) { session.choose_actor('Beta') }
choice = T::MatchEntryScreen::GameChoice.new(program: program, spec: spec, guard: -> { context.current?(lease) }, context: context, lease: lease).run
assert_equal(nil, choice)
driver.finish
context.close
session.close
program.finalize
program.class.app_runtime.close
puts 'PASS own game surface modal: native grid selection, single return, UI thread, account expiry and cleanup'
