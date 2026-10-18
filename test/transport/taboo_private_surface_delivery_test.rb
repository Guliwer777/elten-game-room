require_relative '../support/ui'
require_relative '../support/private_card_games'
require_relative '../support/native_private_messages'
require_relative '../../lib/game_surfaces'
require_relative '../../games/taboo'

# The real private draw arrives after the describing phase and retains that
# phase's token. Use native broker projections, not a manually invented card.
game = GameRoomGames::Taboo.new
h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol Dave])
h.add_client('Observer')
assert(h.join('Observer'), 'observer join failed')
h.as('Observer') { h.transports['Observer'].set_observer(h.table, true, actor: 'Observer') }
viewers = (h.users + ['Observer']).uniq
giver = h.replay('Alice').current_player
play = lambda do |user, action, at = nil|
  replay = h.replay(user)
  context = GameRoomGames::ActionContext.new(table_owner: h.core.owner,
    now: at || [Time.now.to_i, replay.state[:time]].max)
  h.submit(user, {'action' => action, 'token' => game.token(replay.state)}, context: context)
end
play.call(giver, 'start')
play.call(h.core.owner, 'begin', h.replay(giver).state[:deadline])
before = viewers.to_h { |user| [user, h.replay(user)] }
assert(before.values.all? { |replay| replay.state[:phase] == :describing }, 'missing describing transition')
assert(before.values.all? { |replay| game.card_lines(replay.state, replay.state[:private_viewer]).empty? }, 'draw already delivered')
card_keys = %w[c 1 2 3 4 5 6 p b]
viewers.each do |user|
  shortcuts = game.game_shortcuts(before.fetch(user), user)
  assert((shortcuts.map(&:key) & card_keys).empty?, "#{user}: undelivered card has active shortcuts")
  assert(%w[r s].all? { |key| shortcuts.any? { |shortcut| shortcut.key == key } },
    "#{user}: waiting for a card removed time or score shortcuts")
end
layouts = viewers.to_h do |user|
  [user, GameRoomLayout::Screen.new(view_spec: game.game_view_spec(before.fetch(user), user),
    history_items: [], user_items: [], users_header: 'Users', phase: :active)]
end
layouts.each_value { |layout| assert(layout.take_cursor_announcement.nil?, 'undrawn card announced') }
5.times { PrivateCardGamesTest.tick(h, runners) }

viewers.each do |user|
  replay = h.replay(user)
  assert(game.token(replay.state) == game.token(before.fetch(user).state), 'test did not exercise same-token delivery')
  expected = game.card_lines(replay.state, user)
  shortcuts = game.game_shortcuts(replay, user)
  if expected.empty?
    assert((shortcuts.map(&:key) & card_keys).empty?, "#{user}: hidden card has active shortcuts")
  else
    assert(shortcuts.find { |shortcut| shortcut.key == 'c' }&.message == expected.join(', '),
      "#{user}: delivered card shortcut is missing or stale")
    expected.each_with_index do |line, index|
      assert(shortcuts.find { |shortcut| shortcut.key == (index + 1).to_s }&.message == line,
        "#{user}: delivered card line #{index + 1} is wrong")
    end
    action_key, hidden_key = user == giver ? %w[p b] : %w[b p]
    assert(shortcuts.any? { |shortcut| shortcut.key == action_key } &&
      shortcuts.none? { |shortcut| shortcut.key == hidden_key }, "#{user}: wrong card action")
  end
  layout = layouts.fetch(user)
  original = layout.surface
  options = {view_spec: game.game_view_spec(replay, user), history_items: [], user_items: [], users_header: 'Users', phase: :active}
  layout.update(**options)
  assert(layout.surface.equal?(original), 'routine private delivery rebuilt the surface')
  actual = layout.take_cursor_announcement
  assert(actual == (expected.empty? ? nil : expected.join(', ')), "#{user}: late private card not announced exactly once: #{actual.inspect}")
  layout.update(**options)
  assert(layout.take_cursor_announcement.nil?, "#{user}: same card repeated on refresh")
end

# A new slot becomes public UI only after its own take. Old pending speech
# must not survive hiding a card, and chat focus discards rather than queues it.
play.call(giver, 'correct')
rep = h.replay(giver)
assert((game.game_shortcuts(rep, giver).map(&:key) & card_keys).empty?,
  'shortcuts from the previous card survived while waiting for the next one')
layout = layouts.fetch(giver)
options = {history_items: [], user_items: [], users_header: 'Users', phase: :active}
layout.update(**options.merge(view_spec: game.game_view_spec(rep, giver)))
assert(layout.take_cursor_announcement.nil?, 'old card leaked while waiting for the next one')
5.times { PrivateCardGamesTest.tick(h, runners) }
layout.update(**options.merge(view_spec: game.game_view_spec(h.replay(giver), giver)))
layout.surface.take_cursor_announcement(nil)
assert(layout.take_cursor_announcement.nil?, 'late card interrupted after chat focus')

play.call(giver, 'correct')
5.times { PrivateCardGamesTest.tick(h, runners) }
layout.update(**options.merge(view_spec: game.game_view_spec(h.replay(giver), giver)))
# Deliberately do not consume the new announcement before a phase transition.
play.call(h.core.owner, 'timeout', h.replay(giver).state[:deadline])
5.times { PrivateCardGamesTest.tick(h, runners) }
layout.update(**options.merge(view_spec: game.game_view_spec(h.replay(giver), giver)))
assert(layout.take_cursor_announcement.nil?, 'describing speech retained after the card was hidden')
viewers.each do |user|
  assert((game.game_shortcuts(h.replay(user), user).map(&:key) & card_keys).empty?,
    "#{user}: describing shortcuts survived into review")
end
runners.each_value(&:close)
puts 'PASS private Taboo delayed surface delivery: giver/opponents once, no guesser/observer leakage, quiet refresh, chat and phase boundaries'
