require_relative '../support/tournament_presence_native'
require_relative '../support/private_card_games'
require_relative '../support/clock_event_contract'
P = TournamentPresenceNative

%i[new_boundary unknown_boundary bad_epoch save_freeze aborted].each do |mode|
  ClockEventContract.with_server_time do
    game = GameRoomGames::Poker.new
    TournamentForfeitNative.with_fixture(game: game, users: %w[Alice Bob Carol],
      options: game.default_options.merge('variant'=>'holdem')) do |f|
      f.start
      h, clock = f.h, [0.0]
      runners = h.users.to_h { |user| [user, P.runner(f, user, clock)] }
      fired, draw_id = false, nil
      native = h.view('Bob')
      original = native.method(:pool_request)
      native.define_singleton_method(:pool_request) do |operation, params, **args|
        if operation == :take && !fired
          fired = true
          draw_id = params.fetch('message_id')
          h.as('Carol') { h.view('Carol').leave }
          step(h, runners.fetch('Alice'))
          frozen = P.snapshot(h).session
          assert(frozen['__frozen'])
          before = calls[:take]
          assert_raises(GameRoomNetworkErrors::GamePaused) do
            h.write('Bob', [GameRoomPrivateCards.command('initial_hand', '', operation: 'take',
              pool_id: args.fetch(:pool_id), count: params.fetch('count'))])
          end
          assert_equal(before, calls[:take], 'New ordinary input invoked a native take during the pause')
          raw = GameRoomEventProtocol.game_action_packet(session_id: frozen['__id'], sequence: 99,
            control_epoch: frozen['__control_epoch'], events: [{'action'=>'private_ready','value'=>args.fetch(:pool_id)}], actor: 'Bob')
          stack_push(raw, message_id: 'new-raw-private-action')
          case mode
          when :new_boundary then params['context']['b'] = frozen['__game_boundary']
          when :unknown_boundary then params['context']['b'] = 'unrelated-boundary'
          when :bad_epoch then params['context']['e'] = 'unrelated-epoch'
          when :save_freeze, :aborted
            data = {'session_id'=>frozen['__id'], 'frozen'=>true}
            data['aborted'] = true if mode == :aborted
            h.view('Alice').stack_push(GameRoomEventProtocol.record_packet(kind: 'game_boundary', actor: 'Alice', data: data),
              message_id: "legacy-#{mode}")
          end
        end
        original.call(operation, params, **args)
      end
      12.times do
        step(h, runners.fetch('Alice'))
        step(h, runners.fetch('Bob'), 'Bob')
        break if fired
        step(h, runners.fetch('Carol'), 'Carol')
      end
      assert(fired, "#{mode}: the native take boundary was not reached")
      assert_equal(1, h.core.entries.count { |entry| entry['message_id'] == draw_id })
      %w[Alice Bob].each do |user|
        snapshot = P.snapshot(h, user)
        assert(!snapshot.events.any? { |event| event.dig('__server_pool', 'draw_id') == draw_id }, "#{mode}: unrelated receipt applied")
        assert(!snapshot.events.any? { |event| event['move_id'] == 'new-raw-private-action' }, 'Raw game action bypassed the pause')
      end
    ensure
      runners&.each_value(&:close)
    end
  end
end

# Old contexts remain readable; optional boundary identity obeys the same native
# 256-byte limit and does not widen the accepted context's field schema.
base = GameRoomEventProtocol.game_action_packet(session_id: 123, sequence: 1, control_epoch: 'e' * 64,
  events: [{'action'=>'initial_hand', 'value'=>''}], actor: 'Bob')
legacy = GameRoomPrivateCards.context(base)
assert(!legacy.key?('b'))
base['data']['presence_boundary'] = 'b' * 36
current = GameRoomPrivateCards.context(base)
assert_equal('b' * 36, current['b'])
assert(JSON.generate(current).bytesize <= 256)
base['data']['events'][0]['value'] = 'x' * 256
assert_raises(ArgumentError) { GameRoomPrivateCards.context(base) }
puts 'PASS private pause boundary: new input/foreign boundary/epoch/legacy freeze/abort refused, native context bounded'
