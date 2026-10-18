require_relative '../support/assertions'
require_relative '../../lib/tournaments/interrupted_outcome'
require_relative '../../lib/tournaments/standings'
include GameRoomTest::Assertions
T = GameRoomTournaments
units = %w[anna bartek celina]
make = ->(scores, order = 'higher') {
  {'status'=>'scored','kind'=>'round','index'=>1,'event_id'=>23,'scores'=>scores,'order'=>order}
}
outcome = ->(loser:, checkpoint:, started:true, continuation:{'status'=>'cannot_continue'}, people:units) {
  T::InterruptedOutcome.build(units:people,loser:loser,checkpoint:checkpoint,
    started:started,continuation:continuation,event_count:40)
}
points = ->(value) {
  summary=value.fetch('summary').slice('participants','winners','scores','score_order','places').merge('id'=>'fixture')
  T::Standings.calculate(units:summary['participants'],results:[summary],points:T::Standings::MATCH_POINTS).
    to_h { |row| [row['unit'],row['points']] }
}
value=outcome.call(loser:'celina',checkpoint:make.call({'anna'=>80,'bartek'=>30,'celina'=>120}))
assert_equal([['anna'],['bartek'],['celina']],value['summary']['places'])
assert_equal({'anna'=>4,'bartek'=>2,'celina'=>0},points.call(value))
assert_equal(120,value['summary']['scores']['celina'],'Forfeit overwrote the losing player score')
assert_equal('scored_round',value['decision']['basis'])
value=outcome.call(loser:'celina',checkpoint:make.call({'anna'=>-80,'bartek'=>-30,'celina'=>120}))
assert_equal([['bartek'],['anna'],['celina']],value['summary']['places'])
assert_equal({'anna'=>2,'bartek'=>4,'celina'=>0},points.call(value))
value=outcome.call(loser:'celina',checkpoint:make.call({'anna'=>80,'bartek'=>30,'celina'=>-10},'lower'))
assert_equal([['bartek'],['anna'],['celina']],value['summary']['places'])
assert_equal('lower',value['summary']['score_order'])
value=outcome.call(loser:'celina',checkpoint:make.call(units.to_h { |unit| [unit,0] }))
assert_equal('scored_round',value['decision']['basis'],'Completed all-zero round treated as unplayed')
assert_equal([%w[anna bartek],['celina']],value['summary']['places'])
assert_equal({'anna'=>3,'bartek'=>3,'celina'=>0},points.call(value))
%w[higher lower].each do |order|
  value=outcome.call(loser:'celina',checkpoint:make.call({'anna'=>0,'bartek'=>0.0,'celina'=>1},order))
  assert_equal([%w[anna bartek],['celina']],value['summary']['places'],'Numeric integer/float equality did not tie')
end
value=outcome.call(loser:'celina',checkpoint:make.call({'anna'=>9_007_199_254_740_993,'bartek'=>9_007_199_254_740_992.0,'celina'=>0}))
assert_equal([['anna'],['bartek'],['celina']],value['summary']['places'],'Floating conversion erased a distinct integer score')
value=outcome.call(loser:'celina',checkpoint:{'status'=>'none'})
assert_equal('no_scored_round',value['decision']['basis'])
assert_equal(nil,value['summary']['scores'])
assert_equal({'anna'=>3,'bartek'=>3,'celina'=>0},points.call(value))
value=outcome.call(loser:'celina',checkpoint:{'status'=>'unsupported'},started:false,continuation:{'status'=>'unsupported'})
assert_equal('unstarted',value['decision']['basis'])
assert_equal({'anna'=>3,'bartek'=>3,'celina'=>0},points.call(value))
value=outcome.call(loser:'red',checkpoint:{'status'=>'unsupported'},people:%w[blue red],continuation:{'status'=>'unsupported'})
assert_equal([['blue'],['red']],value['summary']['places'],'A whole team must be one competitive unit')
assert_equal({'blue'=>2,'red'=>0},points.call(value))

eight=%w[a b c d e f g h]
eight_scores=eight.each_with_index.to_h { |unit,index| [unit,70-index*10] }.merge('h'=>100)
value=outcome.call(loser:'h',checkpoint:make.call(eight_scores),people:eight)
assert_equal(eight.map { |unit| [unit] },value['summary']['places'])
assert_equal(eight.each_with_index.to_h { |unit,index| [unit,14-index*2] },points.call(value))
value=outcome.call(loser:'h',checkpoint:make.call(eight_scores.merge('b'=>70)),people:eight)
assert_equal([%w[a b],['c'],['d'],['e'],['f'],['g'],['h']],value['summary']['places'])
assert_equal({'a'=>13,'b'=>13,'c'=>10,'d'=>8,'e'=>6,'f'=>4,'g'=>2,'h'=>0},points.call(value))

assert_raises(T::Publication::Invalid) { outcome.call(loser:'celina',checkpoint:{'status'=>'unsupported'}) }
assert_raises(T::Publication::Invalid) { outcome.call(loser:'celina',checkpoint:{'status'=>'none'},continuation:{'status'=>'unsupported'}) }
value=outcome.call(loser:'celina',checkpoint:{'status'=>'none'},continuation:{'status'=>'continue'})
assert_equal({'decision'=>{'loser'=>'celina','mode'=>'continue','basis'=>'continued','checkpoint'=>{'status'=>'none'}}},value,
  'Supported continuation must preserve the checkpoint without fabricating a terminal summary')
assert_raises(T::Publication::Invalid) { outcome.call(loser:'stranger',checkpoint:{'status'=>'none'}) }
assert_raises(T::Publication::Invalid) { outcome.call(loser:'celina',checkpoint:make.call({'anna'=>0,'bartek'=>0})) }
assert_raises(T::Publication::Invalid) { outcome.call(loser:'celina',checkpoint:make.call(units.to_h { |u| [u,Float::NAN] })) }
assert_raises(T::Publication::Invalid) { outcome.call(loser:'celina',checkpoint:make.call(units.to_h { |u| [u,0] }).merge('event_id'=>0)) }

base={'id'=>'fixture','participants'=>units,'winners'=>['anna'],'scores'=>{'anna'=>80,'bartek'=>30,'celina'=>120},
  'places'=>[['anna'],['bartek'],['celina']]}
[[['anna'],['bartek']], [['anna'],['anna'],['celina']], [['bartek'],['anna'],['celina']], [[],units],
 [['anna'],[['bartek']],['celina']], [['anna'],[42],['celina']]].each do |places|
  assert_raises(T::Publication::Invalid) { T::Standings.calculate(units:units,results:[base.merge('places'=>places)]) }
end
# Legacy result semantics remain unchanged when no explicit placement exists.
legacy=T::Standings.calculate(units:units,results:[base.reject { |key,_| key=='places' }],points:T::Standings::MATCH_POINTS)
assert_equal(2,legacy.find { |row| row['unit']=='celina' }['points'])
puts 'PASS interrupted tournament outcomes: explicit last place, unchanged scores, negative/lower/zero checkpoints, co-winners, closed unsupported policy and legacy standings'
