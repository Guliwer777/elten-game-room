require_relative '../../support/assertions'
require_relative '../../support/mahjong_round'
require_relative '../../../games/mahjong_support/table_events'
include GameRoomTest::Assertions
include MahjongRoundFixture

checked = 0
%w[riichi hong_kong mcr].each do |variant|
  ['123456789m1115z', '1111m234m567p789s', '123m456p789s1155z'].each do |hand|
    flow = ready_flow(hand, '5z', self_draw:true)
    round = GameRoomMahjong::TableRound.new(flow:flow,variant:variant,dealer:0)
    4.times do |stage|
      round.flow.hands.length.times do |seat|
        choices = round.legal_actions(seat:seat)
        candidates = %i[draw replacement win].map { |type| {seat:seat,generation:round.flow.generation,type:type} }
        (0..135).each { |tile| candidates << {seat:seat,generation:round.flow.generation,type: :discard,tile:tile} }
        (0..33).each do |tile|
          %i[riichi concealed_kong added_kong].each { |type| candidates << {seat:seat,generation:round.flow.generation,type:type,tile:tile} }
        end
        candidates += choices
        candidates.each do |action|
          assert_equal(choices.include?(action), round.legal_action?(action))
          checked += 1
        end
        choices.each do |action|
          assert(!round.legal_action?(action.merge(extra:true)), 'extra fields accepted')
          assert(!round.legal_action?(action.merge(generation:round.flow.generation.to_f)), 'floating generation accepted')
        end
      end
      break if round.finished?
      if round.flow.phase == :discard
        round = round.action(seat:round.flow.seat,type: :discard,tile:round.legal_discards.first,generation:round.flow.generation)
      elsif round.window
        seat = round.window.pending.first
        round = round.action(seat:seat,type: :claim,choice:[:pass],generation:round.flow.generation)
      else
        round = round.action(seat:round.flow.seat,type:round.flow.phase,generation:round.flow.generation)
      end
    end
  end
end
puts "PASS Mahjong selected action matches enumeration: #{checked} comparisons, unchanged phase/packet/generation guards"
