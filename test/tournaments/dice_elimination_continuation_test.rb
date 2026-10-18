require_relative '../support/tournament_elimination_model'
require_relative '../../games/farkle'
require_relative '../../games/cat_head_tail'
require_relative '../../games/yahtzee'

check = TournamentEliminationModel.method(:assert)
fixture = TournamentEliminationModel::Fixture

[GameRoomGames::Farkle, GameRoomGames::CatHeadTail, GameRoomGames::Yahtzee].each do |klass|
  f = fixture.new(klass.new)
  check.call(f.game.tournament_forfeit_continuation(f.replay, losing_unit:'Alice', options:f.options)['status'] == 'continue', 'four seats must continue')
  check.call(f.game.tournament_forfeit_continuation(f.replay, losing_unit:'Watcher', options:f.options)['status'] == 'unsupported', 'observer is not a unit')
  f.refuse('Alice', 'tournament_elimination', '[0]')
  ['[]', '[0,0]', '[true]', '[-1]', '[4]', 'null', '{"0":0}'].each do |value|
    f.refuse('Alice', 'tournament_elimination', value, '__tournament_elimination'=>true)
  end
  # Remove both the current seat and a later seat, never compacting the roster.
  f.eliminate('Alice')
  check.call(f.replay.current_player == 'Bob', 'current eliminated seat did not advance')
  f.eliminate('Carol')
  f.assert_roster(%w[Bob Dave])
  check.call(f.replay.state[:tournament_eliminations] == [%w[Alice], %w[Carol]], 'elimination order was lost')
  f.refuse('Alice', 'tournament_elimination', '[0]', '__tournament_elimination'=>true)
  f.refuse('Alice', 'tournament_elimination', '[1]', '__tournament_elimination'=>true)
  check.call(f.game.tournament_forfeit_continuation(f.replay, losing_unit:'Bob', options:f.options)['status'] == 'cannot_continue', 'last opponent is shared terminal outcome')
  grouped = fixture.new(klass.new)
  grouped.eliminate('Alice', 'Carol')
  check.call(grouped.replay.state[:tournament_eliminations] == [%w[Alice Carol]], 'one removed unit was split into different placements')
  grouped.assert_roster(%w[Bob Dave])
end

# Accepted but not banked turn points are lost; earlier scores remain immutable.
f = fixture.new(GameRoomGames::Farkle.new, options:{'score_limit'=>100, 'farkle_rules_version'=>2})
f.append('Alice', 'roll', '1,2,3,4,5,6')
f.append('Alice', 'keep', '0,1,2,3,4,5')
f.eliminate('Alice')
check.call(f.replay.state[:turn_points] == 0 && f.replay.state[:scores]['Alice'] == 0, 'Farkle banked a removed turn')
f.refuse('Alice', 'bank')
f.eliminate('Carol')
f.append('Bob', 'roll', '1,2,3,4,5,6')
f.append('Bob', 'keep', '0,1,2,3,4,5')
f.append('Bob', 'bank')
check.call(f.replay.current_player == 'Dave' && !f.replay.finished?, 'Farkle skipped final opponent')
f.append('Dave', 'roll', '2,2,3,3,4,6')
check.call(f.replay.finished? && f.replay.winner == 'Bob', 'Farkle continuation did not finish naturally')
check.call(f.replay.state[:scores].keys == f.players, 'Farkle dropped original score keys')
f.assert_roster(%w[Bob Dave])

f = fixture.new(GameRoomGames::CatHeadTail.new, options:{'score_limit'=>6})
f.append('Alice', 'roll', '2')
f.append('Alice', 'roll', '6')
f.eliminate('Alice')
check.call(f.replay.state[:scores]['Alice'] == 2 && f.replay.state[:turn_points] == 0, 'Cat changed bank or kept abandoned turn')
f.eliminate('Carol')
f.refuse('Alice', 'roll', '2')
f.append('Bob', 'roll', '6')
f.append('Bob', 'bank')
f.append('Dave', 'roll', '1')
check.call(f.replay.finished? && f.replay.winner == 'Bob', 'Cat did not finish with original score roster')
f.assert_roster(%w[Bob Dave])

# An unfilled eliminated sheet cannot stall either match. Original sheet/total
# keys survive and later match dealer rotation skips the eliminated first seat.
f = fixture.new(GameRoomGames::Yahtzee.new, options:{'matches'=>2, 'extra_categories'=>false,
  'upper_bonus'=>false, 'yahtzee_bonus'=>false, 'joker_rule'=>false})
f.append('Alice', 'roll', '6,6,6,6,6')
f.eliminate('Alice')
f.eliminate('Carol')
check.call(f.replay.state[:turn_rolls] == 0 && f.replay.state[:dice].all?(&:nil?), 'Yahtzee kept removed dice')
f.refuse('Alice', 'score', 'sixes')
2.times do
  26.times do
    result = f.replay
    actor = result.current_player
    category = GameRoomGames::Yahtzee::STANDARD_CATEGORIES.find { |name| !result.state[:sheets][actor].key?(name) }
    f.append(actor, 'roll', actor == 'Bob' ? '6,6,6,6,6' : '1,1,1,1,1')
    f.append(actor, 'score', category)
  end
end
check.call(f.replay.finished? && f.replay.winner == 'Bob', 'Yahtzee failed to finish two active sheets/matches')
check.call(f.replay.state[:totals].keys == f.players, 'Yahtzee discarded original totals')
f.assert_roster(%w[Bob Dave])
puts 'Tournament dice elimination consumers: trusted-only, fixed seats, natural finishes, cold replay OK'
