require_relative '../../support/private_card_games'
require_relative '../../../games/mahjong'

game, users = GameRoomGames::Mahjong.new, %w[Alice Bob Carol Dave]
marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'mahjong-observer'},
  'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1}
h = NativeRoomHarness.new(game: game, users: users, tournament: marker,
  options: game.normalize_options('variant'=>'riichi', 'riichi_winds'=>'0', 'bot_delay'=>0))
h.start
h.add_client('Watcher')
assert(h.join('Watcher'), 'observer did not join')
h.as('Alice') { h.transports['Alice'].transfer_room_owner(h.table, 'Watcher') }
runners = (users + ['Watcher']).to_h { |user| [user, runner_for(h, user)] }
begin
  30.times do
    runners.each do |user, runner|
      begin
        step(h, runner, user)
      rescue => error
        state = h.replay(user)
        actor = game.automatic_actor(state, user, table_owner:'Watcher')
        warn "failed #{user}: #{state.state[:phase]}, actor #{actor}, selection #{game.automatic_action(state, actor, context:GameRoomGames::ActionContext.new(table_owner:'Watcher')).inspect}"
        raise error
      end
    end
  end
  state = h.replay('Watcher').state
  assert(state[:phase] == :playing && !state[:private_error], 'spectator-host setup stalled')
  assert(state[:private_viewer] == 'Watcher' && state[:private_owner] == 'Watcher', 'wrong observer context')
  assert(state[:hands].values.flatten.all? { |tile| GameRoomPrivateCardLedger.hidden?(tile) }, 'spectator host received hand')
  assert(state[:round].flow.dora_indicators.size == 1, 'public indicator blocked behind spectator host')
  assert(h.events('Watcher').size == h.replay('Watcher').accepted_events.size, 'spectator-host wire actions rejected')
  assert(game.legal_actions(h.replay('Watcher'), 'Watcher').empty?, 'observer gained player actions')
  puts 'PASS Mahjong private spectator host: controlled pool setup, player-owned draws, public indicator and no foreign cards'
ensure
  runners.each_value(&:close)
end
