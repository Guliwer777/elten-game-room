require_relative '../../support/ui'
require_relative '../../../lib/game_surfaces'
require_relative '../../support/session_runner'
require_relative '../../../games/mahjong'
require_relative '../../../lib/game_screen'
include GameRoomTest::Assertions

game = GameRoomGames::Mahjong.new
h = NativeRoomHarness.new(game: game, options: game.normalize_options('variant'=>'hong_kong', 'hong_kong_winds'=>'0', 'bot_delay'=>0))
h.start
runner = runner_for(h, 'Alice')
begin
  step(h, runner, count: 3)
  assert_equal(:playing, h.replay('Alice').state[:phase])
  repository = h.repositories.fetch('Bob')
  before = h.replay('Bob')
  screen = GameScreen.new(program: ProgramDouble.new(h.broker.endpoint('Bob')), repository: repository,
    game: game, session: h.session, table: h.table, table_owner: 'Alice', synchronizer: nil,
    room_snapshot_provider: -> { LobbyRepository::TableSnapshot.new(**h.transports['Bob'].room_snapshot(h.table)) })
  h.as('Bob') { screen.send(:prepare_action_view, before) }
  discard = game.legal_actions(h.replay('Alice'), 'Alice').find { |action| action['question_id']&.start_with?('mahjong-discard:') }
  h.submit('Alice', discard)
  after = h.replay('Bob')
  h.as('Bob') do
    view = screen.send(:prepare_action_view, after)
    claims = view.layout.surface.fields_for_parts(['claims']).first
    assert_equal(claims, view.layout.form.fields[view.layout.form.index])
    assert(view.announce_finished_focus, 'New response must queue focus after event speech')
    assert(!view.silent_entry, 'Response focus speech was suppressed')
    repeated = screen.send(:prepare_action_view, after)
    assert(!repeated.announce_finished_focus, 'Refresh repeated the queued focus announcement')
    repeated.layout.form.index = repeated.layout.form.fields.index(repeated.layout.chat)
    reopened = screen.send(:prepare_action_view, after)
    assert_equal([:chat, 0], reopened.layout.focus_location)
    assert(!reopened.announce_finished_focus, 'Chat was interrupted by an existing response')
  end
ensure
  runner.close
  h.as('Alice') { h.view('Alice')&.close }
end
puts 'PASS Mahjong screen: ordinary accepted discard focuses response and queues focus after tile speech once; chat remains untouched'
