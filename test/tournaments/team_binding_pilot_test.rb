require_relative '../support/session_runner'
require_relative '../../games/catalog'
require_relative '../../lib/tournaments/ordinary_team_players'
require_relative '../../lib/tournaments/game_result'
require_relative '../../lib/tournaments/standings'
[
  [GameRoomGames::Spades.new,{'team_size'=>2},2,[0,1,0,1],false],
  [GameRoomGames::Spades.new,{'team_size'=>3},3,[0,1,0,1,0,1],false],
  [GameRoomGames::Domino.new,{'teams'=>true,'team_count'=>'2'},2,[0,1,0,1],true]
].each do |game,changes,size,template,finish|
  people=%w[alice bob carol dave eve frank].first(size*2)
  units=[{'unit_id'=>'red','accounts'=>people.first(size)},{'unit_id'=>'blue','accounts'=>people.last(size)}]
  membership={'version'=>size==2 ? 1 : 2,'kind'=>'fixed-teams','units'=>units}
  membership['team_size']=size if size!=2
  matches=[1,2].map{|leg|{'match_id'=>leg.to_s*64,'leg'=>leg,'unit_ids'=>%w[red blue],'players'=>people}}
  candidate={'game_id'=>game.id,'game_options'=>game.normalize_options(game.default_options.merge(changes).merge('score_limit'=>1)),
    'membership'=>membership,'team_template'=>template,'roster'=>people,'matches'=>matches}
  untouched=JSON.generate(candidate)
  prepared=matches.map{|match|GameRoomTournaments::OrdinaryTeamPlayers.prepare(candidate:candidate,match:match,registry:GameRoomGames::CATALOG)}
  assert_equal(untouched,JSON.generate(candidate),'Preparation mutated the published source')
  prepared.each_with_index do |binding,index|
    order=index==0 ? %w[red blue] : %w[blue red]
    assert_equal(template.map{|side|order[side]},binding['players'].map{|person|person['team']})
    users=binding['players'].map{|person|person['username']}
    h=NativeRoomHarness.new(game:game,users:users,options:binding['options'])
    h.start
    assert_equal(users,h.replay(users.first).players,'Native start changed the planned seats')
    assignment=game.prepared_team_assignment(binding['options'],players:users)
    [0,1].each do |side|
      expected=binding['players'].select{|person|person['team']==order[side]}.map{|person|person['username']}
      assert_equal(expected,assignment.members_for(side),'Native game changed the tournament team')
    end
    next unless finish
    context=GameRoomGames::ActionContext.new(random_source:GameRoomRandom::LocalSecureSource.new)
    runners=users.to_h{|user|[user,runner_for(h,user)]}
    begin
      1024.times do
        runners.each{|user,runner|step(h,runner,user)}
        replay=h.replay(users.first)
        break if replay.finished?
        actor=replay.current_player
        own=h.replay(actor)
        actions=game.legal_actions(own,actor)
        action=actions.find{|value|value['action']=='play'} || actions.first
        next unless action # Native executors advance private deal phases.
        h.submit(actor,action,context:context)
      end
      replay=h.replay(users.first)
      assert(replay.finished?,'Native team game did not finish')
      result=GameRoomTournaments::GameResult.from_replay(game:game,replay:replay,players:binding['players'],
        options:binding['options'],event_count:h.events(users.first).size,result_policy:GameRoomTournaments::GameResult::CURRENT_RESULT_POLICY)
      assert_equal(%w[blue red],result['participants'],'Individual accounts escaped into the team result')
      assert_equal(%w[blue red],result['scores'].keys.sort)
      rows=GameRoomTournaments::Standings.calculate(units:%w[red blue],results:[result.slice('participants','winners','scores','score_order').merge('id'=>'native')],
        points:GameRoomTournaments::Standings::MATCH_POINTS)
      assert_equal(result['draw'] ? [1,1] : [0,2],rows.map{|row|row['points']}.sort)
    ensure
      runners.each_value(&:close)
    end
  end
  broken=JSON.parse(JSON.generate(candidate))
  broken['membership']['units'][1]['accounts'][0]=people.first
  assert_raises(GameRoomTournaments::Publication::Invalid){GameRoomTournaments::OrdinaryTeamPlayers.prepare(candidate:broken,match:broken['matches'].first,registry:GameRoomGames::CATALOG)}
end
puts 'PASS team binding pilot: native Spades 2/3-person team entry, finished Domino first/return games with team scores and 2/1/0 standings, immutable source, swapped sides and invalid membership rejection; no dispatch/server writes'
