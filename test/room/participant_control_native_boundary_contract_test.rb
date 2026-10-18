require_relative '../support/scientific_war_control'

# The actual native broker accepts the changing private commitments and owner.
# Only the cached table's tournament marker is supplied at the menu boundary:
# this tests presentation and preflight, not validation of a tournament binding.
fixture = ScientificWarControlFixture.new(bots: 0, watcher: true)
room = nil
control = nil
refresh_projection = lambda do
  snapshot = fixture.snapshot
  room = fixture.as('Alice') { fixture.app.lobby.snapshot_for(fixture.table) }
  room.table['tournament_match'] = {}
  replay = fixture.game.replay(snapshot.session, snapshot.events, fixture.app.games)
  control = {active: !replay.finished?, players: fixture.app.games.players_for(snapshot.session),
    session: snapshot.session, replay: replay}
end
refresh_projection.call
rows = RoomPresentation.user_rows(room.members, observers: room.observers,
  owner: 'Alice', players: control[:players], active: true)
layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new,
  user_items: rows, users_header: 'Users', phase: :active, own_table: true)
layout.users.index = rows.index { |row| row.participant == 'Bob' }
dispatches, denials = [], []
GameRoomParticipantMenu.bind(layout, available: -> { [:manage_control] },
  game: fixture.game, room: -> { room }, control: -> { control },
  control_denied: ->(message) { denials << message }) { |*arguments| dispatches << arguments }

menu = lambda do |viewer = 'Alice'|
  fixture.as(viewer) do
    result = LifecycleMenu.new
    before_calls = fixture.broker.cores.values.first.views.to_h { |view| [view.user, view.calls.dup] }
    before_events = fixture.broker.cores.values.first.last_seq
    before_speech = $spoken_messages.dup
    before_selection = layout.users.index
    layout.users.context(result, false)
    tips = GameRoomContextHelp.field_tips(layout.users)
    expected_help = result.items.filter_map do |_label, key, _handler|
      {'m' => 'Ctrl+M', 'R' => 'Ctrl+Shift+R'}[key]
    end
    actual_help = %w[Ctrl+M Ctrl+Shift+R].select { |key| tips.any? { |tip| tip.start_with?("#{key},") } }
    assert(expected_help.sort == actual_help.sort, "Menu/help disagree: #{expected_help.inspect} / #{tips.inspect}")
    assert(before_calls == fixture.broker.cores.values.first.views.to_h { |view| [view.user, view.calls.dup] },
      'Reading controls fetched native state')
    assert(before_events == fixture.broker.cores.values.first.last_seq, 'Reading controls wrote native state')
    assert(before_speech == $spoken_messages && layout.users.index == before_selection,
      'Resolving control availability announced or moved the selection')
    result
  end
end

initial = menu.call
assert(initial.items.map { |entry| entry[1] }.sort == %w[R m], 'Fresh public trick lost a permitted control')
old_transfer = initial.items.find { |entry| entry[1] == 'm' }.last
old_replace = initial.items.find { |entry| entry[1] == 'R' }.last

# This is a real accepted secret, not a manually changed replay phase.
fixture.choose('Bob')
refresh_projection.call
assert(control[:replay].state[:commits].key?('Bob'), 'Native commitment was not accepted')
assert(menu.call.items.empty?, 'The selected committed seat still offers unsafe controls')
fixture.as('Alice') { old_transfer.call; old_replace.call }
assert(dispatches.empty? && denials == ['This action is not available now.'] * 2,
  'A retained menu dispatched after a private commitment arrived')
before = fixture.broker.cores.values.first.last_seq
fixture.as('Alice') do
  assert(!fixture.app.send(:change_table_control, fixture.table, :replace_player, 'Bob', replacement: 'Watcher'),
    'Direct UI action bypassed the current private phase')
end
assert(fixture.broker.cores.values.first.last_seq == before, 'Rejected direct action changed the native stack')
assert(fixture.context('Bob').hidden_submissions.reveal(session_id: fixture.session['__id'], round_id: 'trick:1', user: 'Bob'),
  'Rejected control destroyed the original private envelope')

# The restriction is target-specific. Alice has no pending choice yet.
layout.users.index = rows.index { |row| row.participant == 'Alice' }
assert(menu.call.items.map { |entry| entry[1] } == ['R'], 'An unrelated private choice blocked a safe selected seat')
layout.users.index = rows.index { |row| row.participant == 'Bob' }
room.table.delete('tournament_match')
assert(menu.call.items.map { |entry| entry[1] }.sort == %w[R m], 'Ordinary menu visibility was broadened or restricted')
room.table['tournament_match'] = {}

fixture.choose('Alice')
fixture.act('Alice', 'Alice', {'kind' => 'command', 'action' => 'reveal'})
fixture.act('Bob', 'Bob', {'kind' => 'command', 'action' => 'reveal'})
refresh_projection.call
assert(control[:replay].state[:trick] == 2, 'Real play did not reach the next safe boundary')
assert(menu.call.items.map { |entry| entry[1] }.sort == %w[R m], 'Safe boundary did not restore available controls')

# Leave the menu open across a real ownership handover. The original provider
# deliberately still advertises manage_control: the fresh resolver must deny it.
fixture.as('Alice') { assert(fixture.app.send(:change_table_control, fixture.table, :transfer_master, 'Watcher')) }
refresh_projection.call
assert(room.table['owner'] == 'Watcher', 'Native handover did not update the owner projection')
fixture.as('Alice') { old_transfer.call; old_replace.call }
assert(dispatches.empty? && denials.length == 4, 'Former owner retained a menu capability')
assert(menu.call.items.empty?, 'Former owner still sees controls despite newer native ownership')
# As in the actual owner runner, project the new owner's native view so it can
# authenticate the new epoch. The old viewer alone cannot publish that anchor.
fixture.snapshot('Watcher')
refresh_projection.call
new_owner_menu = menu.call('Watcher')
assert(new_owner_menu.items.map { |entry| entry[1] }.sort == %w[R m],
  "New owner cannot see permitted selected-seat controls: #{new_owner_menu.items.map { |entry| entry[1] }.inspect}; room=#{room.table.inspect}; session=#{control[:session].inspect}")

new_transfer = menu.call('Watcher').items.find { |entry| entry[1] == 'm' }.last
fixture.as('Bob') { fixture.transports['Bob'].deactivate_table(table_id: fixture.table['__id']) }
refresh_projection.call
assert(!room.members.include?('Bob') && control[:players].include?('Bob'), 'Fixture did not leave an absent playing seat')
assert(menu.call('Watcher').items.map { |entry| entry[1] } == ['R'], 'Absent participant remained a host-transfer target')
fixture.as('Watcher') { new_transfer.call }
assert(dispatches.empty? && denials.length == 5, 'Retained handover targeted a departed participant')

puts 'PASS participant control native boundaries: accepted private phase, target-specific availability, retained callbacks, direct preflight, new owner, departure, no I/O or focus/speech side effects.'
