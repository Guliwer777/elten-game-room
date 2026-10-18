require_relative '../support/private_card_games'
%w[mille_bornes spades tysiac three_five_eight ninety_nine poker war rummy makao domino mexican_train scrabble biblios uno].each do |name|
  require_relative "../../games/#{name}"
end

classes = [GameRoomGames::MilleBornes, GameRoomGames::Spades, GameRoomGames::Tysiac,
  GameRoomGames::ThreeFiveEight, GameRoomGames::NinetyNine, GameRoomGames::Poker,
  GameRoomGames::War, GameRoomGames::Rummy, GameRoomGames::Makao,
  GameRoomGames::Domino, GameRoomGames::MexicanTrain, GameRoomGames::Scrabble,
  GameRoomGames::Biblios, GameRoomGames::Uno]
classes.each do |klass|
  game = klass.new
  users = %w[Alice Bob Carol]
  marker = {'publication_ref'=>{'author'=>'Alice','publication_key'=>'observer-private'},
    'schedule_id'=>'a'*64,'match_id'=>'b'*64,'leg'=>1}
  h = NativeRoomHarness.new(game:game, users:users, tournament:marker)
  h.start
  h.add_client('Observer')
  assert(h.join('Observer'), "#{game.id}: observer could not join")
  h.as('Observer') { h.transports['Observer'].set_observer(h.table, true, actor:'Observer') }
  h.view('Alice').transfer_ownership(h.view('Alice').participants.find { |p| p.user == 'Observer' })
  runners = (users + ['Observer']).to_h { |user| [user, runner_for(h, user)] }
  32.times { PrivateCardGamesTest.tick(h, runners) }
  state = h.replay('Observer').state
  assert(!state[:private_error], "#{game.id}: private error")
  assert(![:private_prepare,:private_wait,:private_dealing].include?(state[:phase]),
    "#{game.id}: observer host stalled at #{state[:phase]}")
  assert(h.events('Observer').any? { |e| e['action'] == 'initial_hand' || e['action'] == 'private_draw' },
    "#{game.id}: observer host did not deliver private cards")
  hands = state[:hands] || state[:racks] || state[:piles]
  assert(hands.values.flatten.all? { |card| GameRoomPrivateCardLedger.hidden?(card) || state[:private_public].include?(card) },
    "#{game.id}: observer host sees a private hand")
  receipt = state[:private_draws].find { |_, draw| draw[:count] > 0 && draw[:used].size < draw[:count] }
  assert(receipt, "#{game.id}: no private receipt tested")
  assert_raises(EltenLink::Error) { h.view('Observer').pool(receipt.last[:pool]).draw(receipt.first) }
  runners.each_value(&:close)
  puts "PASS #{game.id}: observer host deals without owning a hand"
end
