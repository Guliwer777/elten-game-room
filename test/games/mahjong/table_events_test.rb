require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../../games/mahjong_support/table_events'
include GameRoomTest::Assertions
include MahjongRoundFixture
codec = GameRoomMahjong::TableEvents

actions = [
  {type: :draw}, {type: :replacement}, {type: :win},
  {type: :discard, tile: 135}, {type: :concealed_kong, tile: 33},
  *[[:pass], [:win], [:chow, 24], [:pung, 33], [:kong, 33]].map { |choice| {type: :claim, choice: choice} }
]
actions.each do |fields|
  action = {seat: 3, generation: (1 << 63) - 1}.merge(fields)
  wire = codec.encode(action)
  assert(wire.bytesize <= 64)
  assert_equal(action, codec.decode(wire, seat: 3))
  assert_equal(1, codec.decode(wire, seat: 1)[:seat], 'Only the authenticated adapter assigns the seat')
end
[
  '{}', '[]', '{', 'x' * 65,
  '{"v":true,"g":0,"a":"d"}', '{"v":1,"g":0.0,"a":"d"}',
  '{"v":1,"g":-1,"a":"d"}', '{"v":1,"g":0,"a":"d","seat":0}',
  '{"v":1,"g":0,"a":"x","t":136}', '{"v":1,"g":0,"a":"k","t":34}',
  '{"v":1,"g":0,"a":"c","c":"chow:7"}', '{"v":1,"g":0,"a":"c","c":"pung:034"}',
  '{"v":1,"g":0,"a":"c","c":"win:0"}', '{"v":1,"g":0,"a":"unknown"}'
].each { |wire| assert_equal(nil, codec.decode(wire, seat: 0), wire) }
assert_equal(nil, codec.decode('{"v":1,"g":0,"a":"d"}', seat: 4))
assert_raises(ArgumentError) { codec.encode(seat: 0, generation: 0, type: :discard, tile: 144) }
assert_raises(ArgumentError) { codec.encode(seat: 0, generation: 0, type: :draw, injected: true) }

flow = ready_flow('123456789m1115z', '5z', self_draw: true)
round = GameRoomMahjong::TableRound.new(flow: flow, variant: 'mcr', dealer: 0)
discard = {'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-discard:#{flow.generation}", 'answer'=>flow.hands[0].first.to_s}
selected = codec.selection(discard, round: round, seat: 0)
assert_equal(:discard, selected[:type])
assert_equal(nil, codec.selection(discard.merge('question_id'=>'mahjong-discard:0'), round: round, seat: 0))
assert_equal(nil, codec.selection(discard, round: round, seat: 1))
win = codec.selection({'kind'=>'command', 'action'=>'win', 'generation'=>flow.generation}, round: round, seat: 0)
assert_equal(:win, win[:type])
assert(round.action(**codec.decode(codec.encode(win), seat: 0)).finished?)
assert_equal(nil, codec.selection({'kind'=>'command', 'action'=>'win', 'generation'=>flow.generation.to_s}, round: round, seat: 0))

claiming = round.action(**selected)
actor = claiming.window.pending.first
choice = codec.selection({'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-claim:#{claiming.flow.generation}", 'answer'=>'pass'}, round: claiming, seat: actor)
assert_equal([:pass], choice[:choice])
responded = claiming.action(**codec.decode(codec.encode(choice), seat: actor))
assert_equal(nil, codec.selection({'kind'=>'question', 'action'=>'submit', 'question_id'=>"mahjong-claim:#{responded.flow.generation}", 'answer'=>'pass'}, round: responded, seat: actor))
puts 'PASS mahjong table event boundary: compact payloads, authenticated seats, strict schema, native selection mapping, stale and duplicate rejection'
