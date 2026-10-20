require_relative '../../support/private_card_games'
require_relative '../../../games/mahjong'
$stdout.sync = true
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

game = GameRoomGames::Mahjong.new
variant = ARGV.fetch(0, 'riichi')
users = %w[Alice Bob Carol Dave].first(variant == 'riichi' ? 3 : 4)
h, runners = PrivateCardGamesTest.create(game, users: users,
  options: {'variant'=>variant, 'riichi_seats'=>users.size.to_s,
    'hong_kong_winds'=>'0', 'riichi_winds'=>'0', 'mcr_winds'=>'0'})
begin
  30.times { PrivateCardGamesTest.tick(h, runners) }
  count = 0
  loop do
    replay = h.replay(users.first)
    break if replay.finished?
    assert(!replay.state[:private_error], "#{variant}: audit error #{replay.state[:private_error]} at #{count}")
    assert(count < 500, "#{variant}: round did not finish")
    actor = replay.current_player
    assert(actor, "#{variant}: stalled in #{replay.state[:phase]}")
    mine = h.replay(actor)
    round = mine.state[:round]
    move = {seat: mine.players.index(actor), generation: round.flow.generation}
    if %i[reactions kong_reactions].include?(round.flow.phase)
      move.merge!(type: :claim, choice: [:pass])
    elsif round.flow.phase == :discard
      move.merge!(type: :discard, tile: round.legal_discards.first)
    else
      move[:type] = round.flow.phase
    end
    action = GameRoomMahjong::TableEvents.to_selection(move)
    assert(action, "#{variant}: no action for #{actor} in #{mine.state[:phase]}")
    PrivateCardGamesTest.submit(h, runners, actor, action)
    30.times do
      pending = h.replay(users.first)
      break if pending.finished? || pending.state[:phase] == :playing
      PrivateCardGamesTest.tick(h, runners)
    end
    count += 1
    puts "progress #{variant}: #{count} decisions" if (count % 50).zero?
  end
  replays = users.map { |user| h.replay(user) }
  assert(replays.all?(&:finished?), 'other accounts did not finish')
  assert(replays.all? { |replay| !replay.state[:private_error] }, 'final audit rejected')
  scores = replays.map { |replay| game.participant_scores(replay) }
  assert(scores.uniq.one?, 'audited scores disagree')
  assert(scores.first.values.sum.zero?, 'points do not balance')
  assert(h.events(users.first).size == replays.first.accepted_events.size, 'wire receipt lost')
  puts "PASS Mahjong private full #{variant}: #{count} decisions, #{h.events(users.first).size} accepted receipts, audited result #{scores.first.inspect}; #{(Process.clock_gettime(Process::CLOCK_MONOTONIC)-started).round(2)} seconds"
ensure
  runners.each_value(&:close)
end
