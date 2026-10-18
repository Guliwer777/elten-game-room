require_relative '../../support/assertions'
require_relative '../../support/mahjong_table_game'
require_relative '../../support/mahjong_game'
require_relative '../../support/mahjong_round'
require_relative '../../../games/mahjong'
require_relative '../../../lib/game_sounds'
include GameRoomTest::Assertions
include MahjongRoundFixture

def sound(game, event, before, after)
  game.event_sound_cues(event: event, before_replay: before, after_replay: after,
    history: [], viewer: 'Alice', random_variant: ->(_) { raise 'Unexpected cosmetic randomness' })
end

game = GameRoomGames::Mahjong.new
repo = MahjongTableGameTest::Repository.new
context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongTableGameTest::RandomSource.new)
%w[solitaire hong_kong riichi mcr].each do |variant|
  options = game.normalize_options('variant'=>variant, 'hong_kong_winds'=>'0', 'riichi_winds'=>'0', 'mcr_winds'=>'0')
  session = {'id'=>45, 'players'=>variant == 'solitaire' ? ['Alice'] : %w[Alice Bob Carol Dave], 'options'=>JSON.generate(options)}
  before = game.replay(session, [], repo)
  _, plan = game.action_for(game.automatic_action(before, 'Alice'), before, 'Alice', context: context)
  event = {'id'=>1,'actor'=>'Alice','action'=>plan.events.first.action,'value'=>plan.events.first.value}
  after = game.incremental_replay(before, session, [event], repo)
  assert_equal('domino_refill', sound(game,event,before,after))
  assert_equal(nil, sound(game,event,nil,after))
  assert_equal(nil, sound(game,event,after,after))
  assert_equal(nil, sound(game,event.merge('id'=>999),before,after))
  if variant == 'solitaire'
    %w[remove undo].each_with_index do |operation,index|
      before = after
      selection = operation == 'remove' ? game.legal_actions(before,'Alice').first :
        {'kind'=>'command','action'=>'undo','turn'=>before.state[:turn]}
      _,plan = game.action_for(selection,before,'Alice',context:context)
      event = {'id'=>index+2,'actor'=>'Alice','action'=>plan.events.first.action,'value'=>plan.events.first.value}
      after = game.incremental_replay(before,session,[event],repo)
      assert_equal(operation == 'remove' ? 'domino_move_tile' : 'reverse',sound(game,event,before,after))
    end
  else
    # Real accepted discard, all response events and the following draw.
    heard = []
    20.times do |index|
      before = after
      actor = game.active_actors(before).first
      legal = game.legal_actions(before,actor)
      selection = legal.find { |item| item['answer'] == 'pass' } || legal.first
      _,plan = game.action_for(selection,before,actor,context:context)
      event = {'id'=>index+2,'actor'=>actor,'action'=>plan.events.first.action,'value'=>plan.events.first.value}
      after = game.incremental_replay(before,session,[event],repo)
      cue = sound(game,event,before,after)
      assert_equal(nil,cue) if selection['answer'] == 'pass'
      heard << cue
      break if cue == 'domino_take_chip'
    end
    assert(heard.include?('domino_move_tile'), 'Discard was silent')
    assert(heard.include?('domino_take_chip'), 'Draw was silent')
  end
end

# Actual claim resolution and winning round; a hand can end before a match does.
def round_replay(round, events, finished: false)
  GameRoomGames::Replay.new(players:%w[Alice Bob Carol Dave], accepted_events:events, history:[],
    winner:finished ? 'Alice' : nil, state:{session_id:45, round:round})
end
flow = ready_flow('123456789m1115z','5z',self_draw:true)
round = GameRoomMahjong::TableRound.new(flow:flow,variant:'hong_kong',dealer:0)
won = round.action(seat:0,type: :win,generation:flow.generation)
event = {'id'=>91,'action'=>'mahjong_move'}
assert_equal('win1',sound(game,event,round_replay(round,[]),round_replay(won,[event])))
assert_equal(nil,sound(game,event,round_replay(round,[]),round_replay(won,[event],finished:true)))

flow = ready_flow('123m456p789s1155z','1z')
round = GameRoomMahjong::TableRound.new(flow:flow,variant:'hong_kong',dealer:0)
round = round.with(window: GameRoomMahjong::ClaimOffers.for_discard(flow,
  replacement_available:flow.replacement_available?, win_checker: ->(*) { false }))
first = round
round.window.pending.dup.each do |seat|
  choice = seat == 0 ? [:pung,27] : [:pass]
  round = round.action(seat:seat,type: :claim,choice:choice,generation:round.flow.generation)
end
assert_equal('play2',sound(game,event,round_replay(first,[]),round_replay(round,[event])))
flow = ready_flow('123m456p789s1111z','5z',self_draw:true)
flow = GameRoomMahjong::TileFlow.new(hands:flow.hands,wall:flow.wall,seat:0,
  phase:flow.phase,generation:flow.generation,last_draw:flow.last_draw,
  draw_origin:flow.draw_origin,replacement_source: :wall_back)
round = GameRoomMahjong::TableRound.new(flow:flow,variant:'hong_kong',dealer:0)
kong = round.action(seat:0,type: :concealed_kong,tile:27,generation:flow.generation)
assert_equal('play2',sound(game,event,round_replay(round,[]),round_replay(kong,[event])))
replacement = kong.action(seat:0,type: :replacement,generation:kong.flow.generation)
assert_equal('domino_take_chip',sound(game,event,round_replay(kong,[]),round_replay(replacement,[event])))
%w[domino_refill domino_move_tile domino_take_chip reverse play2 win1 draw].each do |name|
  assert(GameRoomSounds::ASSET_NAMES.include?(name))
  assert(File.file?(File.expand_path("../../../Audio/#{name}.opus",__dir__)))
end
puts 'PASS Mahjong sound cues: accepted deals/moves in four variants, silent Pass/refresh/rejected events, Solitaire undo, resolved pung, hand win and shared final result'
