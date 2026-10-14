require_relative '../support/binary_rules_load' if ARGV.first
require_relative '../support/assertions'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/server_phase_plan'
require_relative '../../lib/tournaments/ordinary_team_players'
include GameRoomTest::Assertions
T=GameRoomTournaments
[false,true].each do |team|
  accounts=%w[guliwer benek liliput pajac second third fourth fifth].first(team ? 8 : 4)
  membership=team ? {'version'=>1,'kind'=>'fixed-teams','units'=>accounts.each_slice(2).with_index.map{|pair,index|{'unit_id'=>"side-#{index}",'accounts'=>pair}}} : nil
  units=team ? membership['units'].map{|unit|unit['unit_id']} : accounts
  game=team ? GameRoomGames::Domino.new : GameRoomGames::TicTacToe.new
  options=team ? game.normalize_options(game.default_options.merge('teams'=>true,'team_count'=>'2')) : game.default_options
  settings={'group_advancement'=>T::GroupAdvancement::COMPACT,'pairing'=>'all_combinations','rematch'=>false}
  matches,groups=T::GroupSchedule.build(roster:units,settings:settings,players_per_match:2)
  matches=matches.each_with_index.map{|match,index|match.merge('match_id'=>(index+1).to_s*64)}
  candidate={'format'=>'groups_knockout','game_id'=>game.id,'game_options'=>options,'roster'=>accounts,'players_per_match'=>team ? 4 : 2,
    'schedule_id'=>'c'*64,'publication_digest'=>'b'*64,'roster_generation'=>'a'*64,'publication_ref'=>{'author'=>'guliwer','publication_key'=>'fixture'},
    'group_advancement'=>T::GroupAdvancement::COMPACT,'groups'=>T::GroupSchedule.metadata(groups,matches),'matches'=>matches,
    'dispatch_allowed'=>false,'start_allowed'=>false,'finalize_allowed'=>false}
  if team
    candidate.merge!('membership'=>membership,'team_template'=>[0,1,0,1])
    matches.each do |match|
      match['unit_ids']=match['players']
      match['players']=match['unit_ids'].flat_map{|id|membership['units'].find{|unit|unit['unit_id']==id}['accounts']}
    end
  end
  results=matches.each_with_index.map do |match,index|
    people=match['unit_ids'] || match['players']
    {'match_id'=>match['match_id'],'leg'=>match['leg'],'summary'=>{'participants'=>people.sort,'winners'=>index==0 ? [] : [people.first],'draw'=>index==0,'scores'=>nil,'event_count'=>9}}
  end
  tiebreak=T::ServerPhasePlan.build(candidate:candidate,results:results)['candidate']
  assert_equal(2,tiebreak['knockout']['qualification']['snapshot']['groups'].size)
  assert_equal(1,tiebreak['matches'].size,'Qualification tie generated unrelated matches')
  points=tiebreak['knockout']['qualification']['snapshot']['groups'].flat_map{|group|group['qualification']['standings']}.to_h{|row|[row['unit'],row['points']]}
  extra=tiebreak['matches'].map do |match|
    people=match['unit_ids'] || match['players']
    {'match_id'=>match['match_id'],'leg'=>match['leg'],'summary'=>{'participants'=>people.sort,'winners'=>[people.first],'draw'=>false,'scores'=>nil,'event_count'=>7}}
  end
  advanced=T::ServerPhasePlan.build(candidate:tiebreak,results:extra)['candidate']
  assert_equal(accounts.sort,advanced['roster'].sort,'Already-qualified competitors disappeared after the tiebreak')
  assert_equal(2,advanced['matches'].size)
  normalized=extra.map{|receipt|receipt['summary'].slice('participants','winners','scores').merge('id'=>JSON.generate([receipt['match_id'],receipt['leg']]))}
  view=T::KnockoutStandings.calculate(candidate:tiebreak,units:tiebreak['knockout']['seeds'],results:normalized,unit_key:team ? 'unit_ids' : 'players')
  after=view['qualification_progress']['projection']['groups'].flat_map{|group|group['qualification']['standings']}.to_h{|row|[row['unit'],row['points']]}
  assert_equal(points,after,'Additional qualification games changed original group points')
  if team
    assert_equal(4,advanced['membership']['units'].size,'Full team membership was not restored after the tiebreak')
    advanced['matches'].each{|match|T::OrdinaryTeamPlayers.prepare(candidate:advanced,match:match,registry:GameRoomGames::CATALOG)}
  end
end
puts 'PASS shared group tiebreak projection: individual/pair extra games only for tied units, original group points retained, already-qualified players and full team membership restored'
