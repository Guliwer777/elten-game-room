require_relative "../support/table_lifecycle_controls_2"

ControlAvailabilityReplay = Struct.new(:state, :done) do
  def finished?; done == true; end
end

$game_room_test_user = 'Alice'
game = GameRoomGames::Uno.new
room = LobbyRepository::TableSnapshot.new(
  table: {'owner' => 'Alice', 'tournament_match' => {}},
  members: %w[Alice Bob Watcher], bots: [], observers: ['Watcher'])
session = {'__id' => 'match-1', '__control_ready' => true}
replay = ControlAvailabilityReplay.new({private_cards: {}}, false)
seats = {active: true, players: %w[Alice Bob], session: session, replay: replay}
actions = [:manage_control]
rows = RoomPresentation.user_rows(room.members, observers: room.observers,
  owner: 'Alice', players: seats[:players], active: true)
layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new,
  history_items: [], user_items: rows, users_header: 'Users', phase: :active, own_table: true)
calls = []
denials = []
GameRoomParticipantMenu.bind(layout, available: -> { actions }, game: game,
  room: -> { room }, control: -> { seats }, control_denied: ->(message) { denials << message }) { |*args| calls << args }
layout.users.index = 1
menu = LifecycleMenu.new
layout.users.context(menu, false)
assert(menu.items.none? { |entry| entry[1] == 'R' }, 'Tournament private hands still offer Ctrl+Shift+R')
assert(menu.items.one? { |entry| entry[1] == 'm' }, 'Private hands hid a permitted table-master transfer')
tips = GameRoomContextHelp.field_tips(layout.users)
assert(tips.none? { |tip| tip.include?('Ctrl+Shift+R') }, 'Help still offers forbidden replacement')
assert(tips.one? { |tip| tip.include?('Ctrl+M') }, 'Help lost permitted master transfer')

menu_for = lambda do
  menu = LifecycleMenu.new
  layout.users.context(menu, false)
  menu
end
assert_commands = lambda do |expected, label|
  keys = menu_for.call.items.map { |entry| entry[1] }.select { |key| ['m', 'R'].include?(key) }
  tips = GameRoomContextHelp.field_tips(layout.users)
  help = ['m', 'R'].select { |key| tips.any? { |tip| tip.include?(key == 'm' ? 'Ctrl+M' : 'Ctrl+Shift+R') } }
  assert(keys.sort == expected.sort && help.sort == expected.sort,
    "#{label}: menu/help differ: #{keys.inspect} / #{help.inspect}")
end

# Preserve the ordinary menu; the execution guard still explains the private
# restriction. A marker on either the table or its session enables filtering.
room.table.delete('tournament_match')
assert_commands.call(%w[m R], 'ordinary private game')
session['__tournament_match'] = {}
assert_commands.call(['m'], 'session-only tournament marker')
session.delete('__tournament_match')
room.table['tournament_match'] = {}

replay.state.delete(:private_cards)
assert_commands.call(%w[m R], 'public tournament game')
replace = menu_for.call.items.find { |entry| entry[1] == 'R' }.last
layout.users.index = 2
replace.call
assert(calls == [[:replace_player, 'Bob']], 'Retained menu lost the selected identity')
assert_commands.call(['m'], 'observer cannot be replaced')
layout.users.index = 1
replay.state[:private_cards] = {}
replace.call
assert(calls.length == 1 && denials.last == 'This action is not available now.', 'Old replacement bypassed the current private-hand guard')
replay.state.delete(:private_cards)

transfer = menu_for.call.items.find { |entry| entry[1] == 'm' }.last
session['__frozen'] = true
assert_commands.call([], 'paused match')
transfer.call
assert(calls.length == 1 && denials.length == 2, 'Old transfer bypassed pause')
session['__aborted'] = true
assert_commands.call(['m'], 'aborted match permits only master transfer')
session['__control_ready'] = false
assert_commands.call([], 'aborted transfer awaits authoritative control')
session['__control_ready'] = true
session.delete('__aborted')
session.delete('__frozen')

seats[:active] = false
replay.done = true
assert_commands.call(['m'], 'finished match')
seats[:active] = true
replay.done = false
seats[:replay] = nil
assert_commands.call([], 'unavailable replay')
seats[:replay] = replay

actions.clear
assert_commands.call([], 'lost permission')
actions << :manage_control
room.table['owner'] = 'Bob'
transfer.call
assert(calls.length == 1, 'A cached menu retained ownership after a new room projection')
assert_commands.call([], 'changed room owner')
room.table['owner'] = 'Alice'
room.members.delete('Bob')
assert_commands.call(['R'], 'disconnected seat can still have an available replacement')
room.members << 'Bob'
seats[:players] = %w[Alice Watcher]
assert_commands.call(['m'], 'former player is no longer a replacement source')
seats[:players] = %w[Alice Bob]
assert(calls.length == 1, 'Reading help or building a menu dispatched an operation')

# All policies below use the games' existing capability hooks, not a menu's
# list of game identifiers. No-bot games can still replace a human with a human.
policy = lambda do |definition, model, state = session|
  GameRoomParticipantMenu.control_actions(available: [:manage_control], room: room,
    control: {active: !model.finished?, players: %w[Alice Bob], session: state, replay: model},
    game: definition, participant: 'Bob', viewer: 'Alice')
end
assert(policy.call(GameRoomGames::Scrabble.new, replay) == [:transfer_master, :replace_player], 'No-bot game lost a human replacement')
room.members.delete('Watcher')
assert(policy.call(GameRoomGames::Scrabble.new, replay) == [:transfer_master], 'No-bot game offers an empty replacement picker')
room.members << 'Watcher'
%w[QuizParty Categories].each do |name|
  definition = GameRoomGames.const_get(name).new
  %i[answering revealing].each do |phase|
    model = ControlAvailabilityReplay.new({phase: phase}, false)
    assert(policy.call(definition, model).empty?, "#{name}/#{phase}: private phase exposed control actions")
  end
  model = ControlAvailabilityReplay.new({phase: :round_complete}, false)
  assert(policy.call(definition, model).include?(:transfer_master), "#{name}: public boundary is blocked")
end
[GameRoomGames::Battleship.new, GameRoomGames::Krowa.new].each do |definition|
  model = ControlAvailabilityReplay.new({phase: :playing}, false)
  assert(policy.call(definition, model).empty?, "#{definition.id}: private active game is transferable")
  aborted = session.merge('__aborted' => true, '__frozen' => true)
  assert(policy.call(definition, model, aborted) == [:transfer_master], "#{definition.id}: abandoned private data blocked the waiting room")
end
war = GameRoomGames::ScientificWar.new
model = ControlAvailabilityReplay.new({players: %w[Alice Bob], commits: {'Alice' => 'sealed'}, reveals: {}}, false)
assert(policy.call(war, model) == [:replace_player], 'A different pending seat blocked a safe individual replacement')
model.state[:commits]['Bob'] = 'sealed'
assert(policy.call(war, model).empty?, 'The pending selected seat remained replaceable')

puts 'Participant controls: shared menu/help, ordinary behavior, private/frozen/aborted/finished phases, owner/seat changes and stale callbacks: OK'
