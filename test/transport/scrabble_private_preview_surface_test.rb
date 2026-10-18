require_relative '../support/pong_client'
require_relative '../support/private_card_games'
require_relative '../support/native_public_messages'
require_relative '../support/word_picker'
require_relative '../../games/scrabble'
require_relative '../../lib/scrabble_preview'

# Private dealing/refill uses the shared waiting surface, not a word board.
# Exercise actual broker receipts and view changes, including the preview
# client which model-only private-card tests do not instantiate.
game = GameRoomGames::Scrabble.new
marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'scrabble-preview'},
  'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1}
h = NativeRoomHarness.new(game: game, users: %w[Alice Bob], tournament: marker,
  options: game.normalize_options('content_language_id'=>'en'))
h.start
h.view('Alice').next_random_values = Array.new(16, 8)
h.add_client('Watcher')
assert(h.join('Watcher'), 'observer could not join')
h.as('Watcher') { h.transports['Watcher'].set_observer(h.table, true, actor: 'Watcher') }
runners = h.users.to_h { |user| [user, runner_for(h, user)] }
viewers = h.users + ['Watcher']
clients, layouts, old_boards, phases = {}, {}, {}, Hash.new { |hash, key| hash[key] = [] }
now = 0.0
viewers.each do |user|
  client = GameRoomScrabblePreview.new(ProgramDouble.new(h.broker.endpoint(user)), game,
    transport: h.transports.fetch(user), clock: -> { now })
  client.bind_screen(session_id: h.session['__id'], table_id: h.table['__id'],
    owner: 'Alice', viewer: user, members: -> { viewers })
  client.start
  client.update_table_control('__control_epoch'=>1)
  clients[user] = client
end

present = lambda do
  viewers.each do |user|
    replay, client = h.replay(user), clients.fetch(user)
    phases[user] << replay.state[:phase]
    spec = {view_spec: game.game_view_spec(replay, user), history_items: [],
      user_items: [], users_header: 'Users', phase: :active}
    if layouts[user]
      layouts[user].update(**spec)
    else
      layouts[user] = GameRoomLayout::Screen.new(**spec)
    end
    layout = layouts.fetch(user)
    client.before_wait(replay, user)
    client.attach_view(layout.form, layout.surface)
    client.attach_view(layout.form, layout.surface)
    if layout.surface.is_a?(GameSurfaces::WordBoardSurface)
      assert(layout.surface.on_draft_changed, "#{user}: board preview not attached")
      old_boards[user] = layout.surface
    else
      assert(client.instance_variable_get(:@surface).nil?, "#{user}: placeholder bound as a word board")
      assert(old_boards[user]&.on_draft_changed.nil?, "#{user}: retired board retained its callback")
    end
    timer = client.instance_variable_get(:@progress).timer
    assert(layout.form.instance_variable_get(:@timers).count(timer) == 1,
      "#{user}: missing or duplicate preview timer")
    client.tick
  end
  now += 0.13
end

begin
  24.times do
    present.call
    PrivateCardGamesTest.tick(h, runners)
  end
  present.call
  PrivateCardGamesTest.assert_private(h)
  assert(phases.values.all? { |items| items.include?(:private_prepare) && items.include?(:playing) },
    'native initial private deal did not exercise both surface types')

  actor = h.replay('Alice').current_player
  before = h.replay(actor)
  ids = before.state[:racks].fetch(actor).first(2)
  PrivateCardGamesTest.submit(h, runners, actor, {'action'=>'exchange', 'tiles'=>ids})
  40.times do
    present.call
    PrivateCardGamesTest.tick(h, runners)
  end
  present.call
  PrivateCardGamesTest.assert_private(h)
  assert(h.replay(actor).state[:phase] == :playing &&
    h.replay(actor).state[:revision] == before.state[:revision] + 1,
    'native exchange did not return to the board')
  assert(phases.values.all? { |items| items.include?(:private_show) },
    "native exchange never displayed its waiting surface: #{phases.transform_values(&:uniq).inspect}")
  assert(viewers.all? { |user| layouts.fetch(user).surface.is_a?(GameSurfaces::WordBoardSurface) },
    'player or observer did not return to the word board')
ensure
  clients.each_value(&:close)
  runners.each_value(&:close)
end
assert(clients.values.all? { |client| client.instance_variable_get(:@progress).closed? },
  'preview progress survived closing')
assert(old_boards.values.all? { |board| board.on_draft_changed.nil? }, 'closed preview retained a callback')
puts 'PASS private Scrabble preview: real deal/exchange, waiting/board transitions, both players and observer, bounded timer and cleanup'
