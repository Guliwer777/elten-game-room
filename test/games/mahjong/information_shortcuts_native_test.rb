require_relative '../../support/game_option_editor_native'
require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../support/mahjong_added_kong'
include GameRoomTest::Assertions
include MahjongRoundFixture
include MahjongAddedKongFixture

def info_replay(round, players = %w[Alice Bob Carol Dave])
  GameRoomGames::Replay.new(players: players, accepted_events: [], history: [],
    state: {round:round, profile:{'variant'=>round.variant}, session_id:77, hand_number:3, match:nil, phase: :playing})
end

def info_key(game, replay, viewer, key, modifiers = [])
  game.game_shortcuts(replay,viewer).find { |item| item.key == key && item.modifiers == modifiers }
end

%w[en pl cs es ru].each do |language|
  NativeOptionTest.language = language
  %w[hong_kong riichi mcr].each do |variant|
    game = EltenGameRoom::GAME_REGISTRY.build('mahjong')
    flow = ready_flow('123456789m1115z','5z',self_draw:true)
    round = GameRoomMahjong::TableRound.new(flow:flow,variant:variant,dealer:0)
    replay = info_replay(round)
    before = Marshal.dump(replay)
    shortcuts = game.game_shortcuts(replay,'Alice')
    assert(shortcuts.find { |item| item.key=='w' }.message.include?(round.winning_result(0, include_ura:false).payments.fetch(0).to_s))
    %w[w u r].each do |key|
      shortcut = info_key(game,replay,'Alice',key)
      assert(shortcut && shortcut.kind==:announcement)
      assert(shortcut.label.valid_encoding? && shortcut.message.valid_encoding?)
      spoken=[]
      screen=GameScreen.allocate
      screen.define_singleton_method(:speak) { |text,**_| spoken << text }
      assert_equal(nil,screen.send(:activate_game_shortcut,shortcut,nil,replay:replay))
      assert_equal([shortcut.message],spoken)
    end
    assert(info_key(game,replay,'Alice','r').message.include?('3'))
    assert(info_key(game,replay,'Alice','u',[:shift]).message.include?('Bob'))
    observer = game.game_shortcuts(replay,'Observer')
    assert(observer.none? { |item| %w[w i].include?(item.key) || item.key=='u' && item.modifiers.empty? })
    assert_equal(variant=='riichi',!info_key(game,replay,'Alice','i').nil?)
    assert_equal(before,Marshal.dump(replay),'Announcements mutated the replay')

    # Both U variants read only declared melds, never another hand.
    meld_round=GameRoomMahjong::TableRound.new(flow:added_kong_flow,variant:variant,dealer:0)
    meld_replay=info_replay(meld_round)
    own = info_key(game,meld_replay,'Bob','u').message
    assert(own.include?(GameRoomMahjong::TileLabels.label(8)))
    assert(!own.include?('Alice'))
    others=info_key(game,meld_replay,'Bob','u',[:shift]).message
    assert(others.include?('Alice') && !others.include?('Bob'))

    # Incomplete hands report no legal win, rather than a fabricated fan count.
    empty_round=GameRoomMahjong::TableRound.new(flow:ready_flow('123456m23455p67s','1z',self_draw:true),variant:variant,dealer:0)
    no_win=info_key(game,info_replay(empty_round),'Alice','w')
    assert(no_win && !no_win.message.match?(/\d/))
    ron_flow=ready_flow('123456789m1115z','5z')
    ron_round=GameRoomMahjong::TableRound.new(flow:ron_flow,variant:variant,dealer:0)
    ron_round=ron_round.with(window:GameRoomMahjong::ClaimOffers.for_discard(ron_flow,
      win_checker: ->(seat,*) { !ron_round.winning_result(seat).nil? }))
    claim_value=info_key(game,info_replay(ron_round),'Alice','w')
    assert(claim_value.message.include?(ron_round.winning_result(0,include_ura:false).payments[0].to_s))
    ended=round.action(seat:0,type: :win,generation:flow.generation)
    assert(info_key(game,info_replay(ended),'Alice','w').message.include?(ended.result.payments[0].to_s))
  end
  game=EltenGameRoom::GAME_REGISTRY.build('mahjong')
  sanma=GameRoomMahjong::TableRound.new(flow:GameRoomMahjong::RiichiDeal.shuffled(seed:17,seats:3),variant:'riichi',dealer:0)
  sanma_replay=info_replay(sanma,%w[Alice Bob Carol])
  assert(info_key(game,sanma_replay,'Carol','i'))
  assert(info_key(game,sanma_replay,'Carol','r').message.include?(GameRoomMahjong::TileLabels.label(29*4)))
end

# A genuine accepted Riichi wall: hidden ura changes the final score but
# must never change any pre-win information shortcut.
NativeOptionTest.language='en'
game=EltenGameRoom::GAME_REGISTRY.build('mahjong')
base=ready_flow('123456789m1115z','5z',self_draw:true)
rest=base.wall.dup
indicator=rest.find { |tile| GameRoomMahjong::Tiles.kind(tile)==32 }
ura=rest.find { |tile| GameRoomMahjong::Tiles.kind(tile)==30 }
other=rest.find { |tile| GameRoomMahjong::Tiles.kind(tile)==19 }
rest-=[indicator,ura,other]
reserve=rest.shift(14)
# Swap selected indicators into the reserve without duplicating physical tiles.
[ [4,indicator], [9,ura] ].each { |index,tile| rest << reserve[index]; reserve[index]=tile }
rest << other
flow=GameRoomMahjong::TileFlow.new(hands:base.hands,wall:rest,reserve:reserve,seat:0,
  phase: :discard,last_draw:base.last_draw,draw_origin: :normal,replacement_source: :riichi)
ledger=GameRoomMahjong::RiichiState.new(points:[29000,30000,30000,30000],starting_points:[30000]*4,
  levels:[1,0,0,0],waits:[[31],[],[],[]],sticks:1)
round=GameRoomMahjong::TableRound.new(flow:flow,variant:'riichi',dealer:0,riichi_state:ledger)
assert(round.winning_result(0).score.han > round.winning_result(0,include_ura:false).score.han)
first=info_replay(round)
w=info_key(game,first,'Alice','w')
assert(w.message.include?('excludes hidden ura-dora'))
assert(w.message.include?((round.winning_result(0,include_ura:false).payments[0]+1000).to_s))
other_rest=rest.dup
other_rest.delete(other)
other_rest << reserve[9]
other_reserve=reserve.dup
other_reserve[9]=other
second_flow=GameRoomMahjong::TileFlow.new(hands:flow.hands,wall:other_rest,reserve:other_reserve,seat:0,
  phase: :discard,last_draw:flow.last_draw,draw_origin: :normal,replacement_source: :riichi)
second=info_replay(GameRoomMahjong::TableRound.new(flow:second_flow,variant:'riichi',dealer:0,riichi_state:ledger))
%w[w i r].each { |key| assert_equal(info_key(game,first,'Alice',key).message,info_key(game,second,'Alice',key).message) }

# Furiten from one's own discards and temporary/after-Riichi refusal are distinct.
ron_flow=ready_flow('123456789m1115z','5z',own_discard:'5z')
blocked=GameRoomMahjong::TableRound.new(flow:ron_flow,variant:'riichi',dealer:0)
blocked=blocked.with(window:GameRoomMahjong::ClaimOffers.for_discard(ron_flow,win_checker: ->(*) { false }))
assert(info_key(game,info_replay(blocked),'Alice','i').message.include?('is blocked'))
temporary=blocked.with(furiten:[true,false,false,false])
assert(info_key(game,info_replay(temporary),'Alice','i').message.include?('self-draw is still possible'))
puts 'PASS native Mahjong W/U/Shift+U/R/I: all languages/variants, read-only announcements, exposed meld privacy, legal values, deposit and hidden ura isolation, furiten'
