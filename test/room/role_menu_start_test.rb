require_relative '../support/axel_pong_doubles_lobby'
require_relative '../support/table_lifecycle_controls_2'

include PongDoublesLobbyTest

def make_role_table(team_size: 0)
  app = PongDoublesLobbyApp.new
  app.define_singleton_method(:speak) { |text, **_| @notices << text }
  game = GameRoomGames::AxelPong.new
  options = game.default_options.merge('team_size' => team_size)
  table = app.lobby.create_table(name: 'Roles', game: game.id, owner: 'Alice', game_options: JSON.generate(options)).table
  %w[Bob Carol Dave].each { |user| PongDoublesLobbyTest.join(app, table, user) }
  [app, table, game]
end

def select_role(app, table, game, label, target)
  snapshot = app.lobby.snapshot_for(table, force: true)
  layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new,
    user_items: RoomPresentation.user_rows(snapshot.members, observers: snapshot.observers,
      owner: 'Alice', players: [], active: false))
  requested = []
  GameRoomParticipantMenu.bind(layout,
    available: -> { GameRoomParticipantMenu.role_actions(room: snapshot, viewer: Session.name, owner: 'Alice') },
    game: game, room: -> { snapshot }) do |action, participant|
    requested << [action, participant]
    app.send(:change_observer_mode, table, action, participant)
  end
  layout.users.index = snapshot.members.index(target)
  menu = LifecycleMenu.new
  layout.form.context(menu)
  layout.users.context(menu, false)
  item = menu.items.find { |entry| entry.first == label }
  assert(item, "Missing unambiguous menu label: #{label}")
  item.last.call
  requested
end

app, table, game = make_role_table
assert(select_role(app, table, game, 'I want to observe the next game', 'Bob') == [[:observe_next_game, nil]], 'Self action targeted the selected row')
assert(app.lobby.snapshot_for(table, force: true).observers == ['Alice'], 'Self action changed another user')
assert(select_role(app, table, game, 'Make Bob an observer for the next game', 'Bob') == [[:make_observer, 'Bob']], 'Named action did not target Bob')
assert(select_role(app, table, game, 'Make Bob a player for the next game', 'Bob') == [[:make_player, 'Bob']], 'Named player action lost its subject')
assert(select_role(app, table, game, 'I want to play in the next game', 'Bob') == [[:play_next_game, nil]], 'Self player action changed another user')

[0, 2].each do |team_size|
  (0..4).each do |count|
    next if count == (team_size == 2 ? 4 : 2)
    app, table, = make_role_table(team_size: team_size)
    all = %w[Alice Bob Carol Dave]
    all.drop(count).each { |person| app.lobby.set_observer(table, person, true) }
    assert(app.send(:start_new_game, table).nil?, 'Wrong roster started a game')
    expected = team_size == 2 ? 'Doubles requires exactly four players.' : 'Single requires exactly two players.'
    names = count.zero? ? 'None' : all.first(count).join(', ')
    assert(app.notices.last == "#{expected}\nPlayers: #{names}.", "Wrong variant/count/roster diagnostic: #{app.notices.last}")
    assert_no_game(app, table)
  end
end

# Actual roles still control the start; labels do not change permissions or
# overwrite a running match's roster when choosing roles for the next one.
app, table, game = make_role_table
%w[Bob Dave].each { |person| app.lobby.set_observer(table, person, true) }
first = app.send(:start_new_game, table)
assert(first && app.games.players_for(first) == %w[Alice Carol], 'Valid single did not start')
app.send(:change_observer_mode, table, :make_player, 'Bob')
app.send(:change_observer_mode, table, :make_observer, 'Carol')
assert(app.games.players_for(first) == %w[Alice Carol], 'Role choice changed active players')
assert(app.transport.abort_game(first), 'Could not end the prior game')
second = app.send(:start_new_game, table)
assert(second && app.games.players_for(second) == %w[Alice Bob], 'Next game ignored chosen roles')
puts 'PASS self/named role menu, all rejected single/double rosters, observer host, valid start and immutable active roster'
