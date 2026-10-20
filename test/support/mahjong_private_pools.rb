require_relative 'private_card_games'
require_relative '../../games/mahjong'

# Explicit receipt tapes exercise rare legal boundaries, not RNG quality.
# Production code still receives the ordinary authenticated pool metadata.
module MahjongTestPoolOrder
  def create_pool(**arguments)
    pool = super
    requested = @core.instance_variable_get(:@mahjong_test_pool_order)
    pool_data(pool.id)[:remaining] = requested.dup if requested
    pool
  end

  def pool_request(operation, params, pool_id:, **arguments)
    if operation == :take && (fixture = @core.instance_variable_get(:@mahjong_fixture))
      source = pool_data(pool_id)[:remaining]
      requested = if fixture[:tapes]
        tape = fixture[:tapes][[params.dig('context', 'a'), user]]
        tape&.shift
      else
        case params.dig('context', 'a')
        when 'initial_hand'
          user == 'Alice' ? fixture[:ready] : (source - fixture.values.flatten).first(params['count'])
        when 'mahjong_indicator' then [fixture[:indicator]]
        when 'mahjong_take' then [fixture[:extra]]
        end
      end
      if requested
        raise 'Invalid Mahjong receipt tape' unless requested.size == params['count'] && (requested - source).empty?
        source.replace(requested + (source - requested))
      end
    end
    super(operation, params, pool_id: pool_id, **arguments)
  end
end
NativeLiveSessionsBroker::View.prepend(MahjongTestPoolOrder)

module MahjongPrivateTest
  module_function

  def settle(h, runners)
    24.times do
      replay = h.replay(h.users.first)
      break if replay.finished? || replay.state[:private_error] ||
        %i[playing between_hands].include?(replay.state[:phase]) && !replay.state[:private_opening]
      PrivateCardGamesTest.tick(h, runners)
    end
  end

  def create(variant, hands:, extra:, draws: {}, winds: 0)
    game, users = GameRoomGames::Mahjong.new, %w[Alice Bob Carol Dave]
    marker = {'publication_ref'=>{'author'=>'Alice', 'publication_key'=>'mahjong-cases'},
      'schedule_id'=>'a'*64, 'match_id'=>'b'*64, 'leg'=>1}
    options = game.normalize_options('variant'=>variant, 'hong_kong_winds'=>winds.to_s,
      'riichi_winds'=>winds.to_s, 'mcr_winds'=>winds.to_s, 'bot_delay'=>0)
    deck = GameRoomMahjong::Tiles.set(bonuses: variant != 'riichi')
    missing = users - hands.keys
    held = hands.values.flatten + [extra] + draws.values.flatten
    available = (deck - held).select { |tile| tile < 136 }
    hands = hands.dup
    missing.each { |user| hands[user] = available.shift(13) }
    h = NativeRoomHarness.new(game: game, users: users, tournament: marker, options: options)
    tapes = hands.to_h { |user, hand| [['initial_hand', user], [hand]] }
    tapes[['mahjong_take', 'Alice']] = [[extra]]
    draws.each { |user, tiles| tapes[['mahjong_take', user]] = Array(tiles).map { |tile| [tile] } }
    h.core.instance_variable_set(:@mahjong_fixture, {tapes: tapes.transform_values do |batches|
      batches.map { |tiles| tiles.map { |tile| deck.index(tile) + 1 } }
    end})
    h.start
    runners = users.to_h { |user| [user, runner_for(h, user)] }
    settle(h, runners)
    [game, h, runners]
  end

  def submit(h, runners, actor, answer: nil, command: nil)
    replay = h.replay(actor)
    actions = h.game.legal_actions(replay, actor)
    selection = actions.find { |item| answer ? item['answer'] == answer.to_s : item['action'] == command }
    raise "Missing Mahjong action #{actor}: #{answer || command}" unless selection
    PrivateCardGamesTest.submit(h, runners, actor, selection)
    settle(h, runners)
  end
end
