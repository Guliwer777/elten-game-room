require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
include GameRoomTest::Assertions
include MahjongRoundFixture

# A real ownership model with incomplete hands, a concealed dragon triplet,
# the player's wind triplet and owned bonus tiles. No hypothetical winning tile.
def progress_round(variant, flowers: [], exposed: false, wind: 29)
  base = ready_flow('111555m333777z2p', '4p', self_draw: true)
  hands, melds = base.hands.map(&:dup), base.melds.map(&:dup)
  if exposed
    tiles = hands[0].select { |tile| GameRoomMahjong::Tiles.kind(tile) == 33 }
    hands[0] -= tiles
    melds[0] << {type: :pung, first_kind: 33, tiles: tiles, from: 1}
  end
  flow = GameRoomMahjong::TileFlow.new(hands: hands, melds: melds, wall: base.wall,
    seat: 0, phase: :discard, last_draw: base.last_draw, draw_origin: :normal,
    flowers: [flowers, [], [], []])
  GameRoomMahjong::TableRound.new(flow: flow, variant: variant, dealer: 2, round_wind: wind)
end

def progress_replay(round, enabled: true)
  profile = {'variant'=>round.variant}
  profile['fan_progress'] = 'no' unless enabled
  GameRoomGames::Replay.new(players: %w[Alice Bob Carol Dave], state: {
    round: round, profile: profile, hand_number: 1, session_id: 77, match: nil}, accepted_events: [], history: [])
end

def progress_key(game, replay, viewer = 'Alice')
  game.game_shortcuts(replay, viewer).find { |key| key.key == 'w' }
end

game = EltenGameRoom::GAME_REGISTRY.build('mahjong')
NativeOptionTest.language = 'en'
[false, true].each do |exposed|
  round = progress_round('hong_kong', flowers: [138, 142], exposed: exposed)
  items = GameRoomMahjong::FanProgress.items(round, 0)
  assert_equal(5, items.sum(&:points)) # West twice, red dragon, own flower and season.
  assert_equal(1, items.count { |item| item.type == :dragon })
  before = Marshal.dump(round)
  text = progress_key(game, progress_replay(round)).message
  assert(text.include?('5 fan') && text.include?('Red dragon') && text.include?('Autumn'))
  assert(text.include?('No legal win') && !text.include?('Points gained:'))
  assert_equal(before, Marshal.dump(round))
  assert_equal(nil, progress_key(game, progress_replay(round), 'Observer'))
end
wrong = GameRoomMahjong::FanProgress.items(progress_round('hong_kong', flowers: [139, 141]), 0)
assert_equal(3, wrong.sum(&:points), 'Other seats bonus tiles counted')
full = GameRoomMahjong::FanProgress.items(progress_round('hong_kong', flowers: (136..143).to_a), 0)
assert_equal(7, full.sum(&:points), 'Full families counted their own-seat bonus twice')
round = progress_round('hong_kong')
assert_equal(3, GameRoomMahjong::FanProgress.items(round, 0).sum(&:points), 'Provisional no-flower point counted as certain')
assert(progress_key(game, progress_replay(round)).message.include?('possible extra 1 fan'))
assert(!progress_key(game, progress_replay(round, enabled: false)).message.include?('subtotal'))

mcr = progress_round('mcr', flowers: [138, 142])
items = GameRoomMahjong::FanProgress.items(mcr, 0)
assert_equal(6, items.reject { |item| item.type == :extra_flower }.sum(&:points))
assert_equal(2, items.count { |item| item.type == :extra_flower })
assert(progress_key(game, progress_replay(mcr)).message.include?('do not count towards the minimum of 8'))
riichi = progress_round('riichi')
assert_equal(3, GameRoomMahjong::FanProgress.items(riichi, 0).sum(&:points))
assert(progress_key(game, progress_replay(riichi)).message.include?('3 han'))
assert(progress_key(game, progress_replay(riichi)).message.include?('Dora require'))

# Discarding one of the held dragon tiles immediately removes that triplet.
flow = round.flow
red = flow.hands[0].find { |tile| GameRoomMahjong::Tiles.kind(tile) == 33 }
after = round.with(flow: flow.discard(seat: 0, tile: red, generation: flow.generation))
assert_equal(2, GameRoomMahjong::FanProgress.items(after, 0).sum(&:points))

# The persisted table option must reach both cold and incremental replay,
# without changing accepted events, moves, ownership or scoring.
require_relative '../../support/mahjong_table_game'
%w[hong_kong riichi mcr].each do |variant|
  repo = MahjongTableGameTest::Repository.new
  options = game.normalize_options('variant'=>variant, 'fan_progress'=>'no')
  session = {'id'=>45, 'players'=>%w[Alice Bob Carol Dave], 'options'=>JSON.generate(options)}
  before = game.replay(session, [], repo)
  context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongTableGameTest::RandomSource.new)
  _, plan = game.action_for(game.automatic_action(before, 'Alice'), before, 'Alice', context: context)
  event = {'id'=>1, 'actor'=>'Alice', 'action'=>plan.events.first.action, 'value'=>plan.events.first.value}
  incremental = game.incremental_replay(before, session, [event], repo)
  cold = GameRoomGames::Mahjong.new.replay(session, [event], repo)
  assert_equal('no', cold.state[:profile]['fan_progress'])
  assert_equal(progress_key(game, cold).message, progress_key(game, incremental).message)
  assert(!progress_key(game, cold).message.include?('subtotal'))
  enabled_session = session.merge('options'=>JSON.generate(options.merge('fan_progress'=>'yes')))
  enabled = game.replay(enabled_session, [event], repo)
  assert_equal(cold.accepted_events, enabled.accepted_events)
  assert_equal(cold.state[:round].flow.hands, enabled.state[:round].flow.hands)
  assert_equal(game.legal_actions(cold, 'Alice'), game.legal_actions(enabled, 'Alice'))
end

%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  %w[hong_kong riichi mcr].each do |variant|
    driver = NativeOptionTest::Driver.new(game, initial_options: game.normalize_options('variant'=>variant))
    assert(driver.visible?('fan_progress'))
    driver.focus('fan_progress')
    driver.press([40])
    driver.focus(driver.form.accept_button)
    driver.press([13])
    assert_equal('no', driver.finished.fetch('fan_progress'))
    replay = progress_replay(progress_round(variant))
    shortcut = progress_key(game, replay)
    assert(shortcut.message.encoding == Encoding::UTF_8 && shortcut.message.valid_encoding?)
    assert(!shortcut.message.include?('Basic bonuses from your current')) unless language == 'en'
    spoken = []
    screen = GameScreen.allocate
    screen.define_singleton_method(:speak) { |text, **_| spoken << text }
    screen.send(:activate_game_shortcut, shortcut, nil, replay: replay)
    assert_equal([shortcut.message], spoken)
  end
end
puts 'PASS scoring progress: actual hidden/exposed triplets, own winds/bonuses, full-family replacement, conditional absence, MCR flower separation, Riichi han/dora, discard update, privacy, native W and setting persistence in five languages'
