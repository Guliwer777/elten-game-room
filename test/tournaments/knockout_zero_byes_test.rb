require_relative '../support/assertions'
require_relative '../../lib/tournaments/knockout_round'
include GameRoomTest::Assertions
K=GameRoomTournaments::KnockoutRound
seeds=(1..16).map { |n|"person#{n}" }
# Exhaust every combination of empty first-round branches. Each next match
# must remain within its original bracket branch, even with interleaved byes.
256.times do |mask|
  plan=K.build(seeds:seeds,players_per_match:2,round_number:1)
  slots=plan['matches'].each_with_index.map { |m,i| mask[i]==1 ? nil : m['participants'].first }
  results=plan['matches'].each_with_index.map do |match,i|
    value={'id'=>match['id'],'participants'=>match['participants'],'winners'=>slots[i] ? [slots[i]] : [],'scores'=>nil}
    value['resolution']='all_zero' unless slots[i]
    value
  end
  view=K.progress(seeds:seeds,players_per_match:2,round_number:1,results:results)
  round=2
  while slots.compact.size>1
    expected_groups=slots.each_slice(2).map(&:compact)
    if expected_groups.none? { |group|group.size==2 }
      slots=expected_groups.map(&:first)
      round+=1
      next
    end
    next_plan=K.build(seeds:view['next_seeds'],players_per_match:2,
      round_number:view.fetch('next_round',round),bracket_groups:view['next_bracket_groups'])
    assert_equal(expected_groups.select { |g|g.size==2 },next_plan['matches'].map { |m|m['participants'] },"Bracket reseeded for mask #{mask}")
    assert_equal(expected_groups.select { |g|g.size==1 }.flatten,next_plan['byes'],"Wrong opponent received bye for mask #{mask}")
    assert_equal(next_plan,K.from_metadata(next_plan))
    slots=expected_groups.map(&:first)
    receipts=next_plan['matches'].map { |m| {'id'=>m['id'],'participants'=>m['participants'],'winners'=>[m['participants'].first],'scores'=>nil} }
    view=K.progress(seeds:next_plan['seeds'],players_per_match:2,round_number:next_plan['round'],
      bracket_groups:next_plan['bracket_groups'],results:receipts)
    round+=1
  end
  assert_equal('completed',view['state'])
  assert_equal(slots.compact.first,view['champion'])
end
puts 'PASS all 256 empty-branch combinations in a 16-player bracket; exact opponent byes and no artificial winners'
