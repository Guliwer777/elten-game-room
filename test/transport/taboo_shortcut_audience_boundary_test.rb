require_relative '../support/ui'
require_relative '../support/private_card_games'
require_relative '../support/native_private_messages'
require_relative '../../lib/game_surfaces'
require_relative '../../games/taboo'

game = GameRoomGames::Taboo.new
h, runners = PrivateCardGamesTest.create(game, users: %w[Alice Bob Carol Dave])
h.add_client('Observer')
assert(h.join('Observer'), 'observer must join through the native membership path')
h.as('Observer') { h.transports['Observer'].set_observer(h.table, true, actor: 'Observer') }
viewers = (h.users + ['Observer']).uniq
keys = %w[c 1 2 3 4 5 6 p b]
checks = 0
verify = lambda do |stage|
  viewers.each do |source|
    replay = h.replay(source)
    viewers.each do |viewer|
      lines = game.card_lines(replay.state, viewer)
      shortcuts = game.game_shortcuts(replay, viewer)
      visible = shortcuts.select { |shortcut| keys.include?(shortcut.key) }
      assert(shortcuts.any? { |shortcut| shortcut.key == 'r' } &&
        shortcuts.any? { |shortcut| shortcut.key == 's' }, "#{stage}: unrelated shortcuts disappeared")
      assert(shortcuts.none? { |shortcut| shortcut.kind == :announcement && shortcut.message.to_s.empty? },
        "#{stage}: invalid announcement shortcut")
      if lines.empty?
        assert(visible.empty?, "#{stage}: #{viewer} accessed #{source}'s private card")
      else
        assert(source.casecmp?(viewer), "#{stage}: foreign replay materialized a card")
        assert(visible.find { |shortcut| shortcut.key == 'c' }.message == lines.join(', '),
          "#{stage}: shortcut card differs from authenticated viewer projection")
        assert(visible.select { |shortcut| shortcut.key.match?(/\A[1-6]\z/) }.map(&:message) == lines,
          "#{stage}: wrong target or forbidden words")
      end
      checks += 1
    end
  end
end
verify.call(:ready)
giver = h.replay('Alice').current_player
play = lambda do |actor, action, at = nil|
  replay = h.replay(actor)
  context = GameRoomGames::ActionContext.new(table_owner: h.core.owner,
    now: at || [Time.now.to_i, replay.state[:time]].max)
  h.submit(actor, {'action' => action, 'token' => game.token(replay.state)}, context: context)
end
play.call(giver, 'start')
verify.call(:preparing)
play.call(h.core.owner, 'begin', h.replay(giver).state[:deadline])
assert(game.card_visible?(h.replay(giver).state, giver), 'describer role must precede private delivery')
assert(game.card_lines(h.replay(giver).state, giver).empty?, 'test must reach undelivered secret')
verify.call(:undelivered)
5.times { PrivateCardGamesTest.tick(h, runners) }
assert(game.card_lines(h.replay(giver).state, giver).size == 6, 'native private draw must arrive')
verify.call(:delivered)
h.view(h.core.owner).transfer_ownership(h.view(h.core.owner).participants.find { |person| person.user == 'Observer' })
runners['Observer'] = runner_for(h, 'Observer')
5.times { PrivateCardGamesTest.tick(h, runners) }
verify.call(:observing_host)
assert(game.card_lines(h.replay('Observer').state, 'Observer').empty?, 'host role must not reveal the phrase')
# Ordinary card shortcuts still use the same action roles and six lines.
ordinary = game.initial_state(%w[A B C D], game.normalize_options({}))
ordinary.merge!(phase: :describing, current_player: 'A', team: 0, card: 0, turn: 1, serial: 1)
ordinary_replay = GameRoomGames::Replay.new(players: ordinary[:players], current_player: 'A', state: ordinary)
%w[A B C D Observer].each do |viewer|
  shortcuts = game.game_shortcuts(ordinary_replay, viewer)
  lines = game.card_lines(ordinary, viewer)
  assert(shortcuts.any? { |shortcut| shortcut.key == 'c' } == !lines.empty?, 'ordinary audience changed')
  assert(shortcuts.any? { |shortcut| shortcut.key == 'p' } == (viewer == 'A'), 'ordinary skip role changed')
  assert(shortcuts.any? { |shortcut| shortcut.key == 'b' } == (%w[B D].include?(viewer)), 'ordinary buzz role changed')
end
begin
  GameRoomGames::GameShortcut.new(key: 'c', label: 'Card', kind: :announcement, message: '')
  raise 'empty announcement validation was weakened'
rescue ArgumentError => error
  assert(error.message.include?('requires a message'), 'unexpected validation failure')
end
runners.each_value(&:close)
puts "PASS independent Taboo shortcuts: #{checks} native replay/viewer boundaries, observer-host privacy and unchanged ordinary roles"
