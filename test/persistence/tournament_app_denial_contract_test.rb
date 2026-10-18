require_relative '../support/saved_games_ui'

class TournamentAppDenialContract < EltenGameRoom
  attr_reader :notices
  def initialize
    @notices = []
    @transport = GameRoomTransport.new(ProgramDouble.new(NativeLiveSessionsBroker.new.endpoint('Alice')))
  end
  def alert(text); @notices << text; end
  def run_network_task(*, **); raise 'Denied tournament operation reached the network'; end
  def game_definition(*); raise 'Denied tournament operation started loading a game'; end
  def saved_games; raise 'Denied tournament operation opened archive storage'; end
  def confirm(*); raise 'Denied tournament operation opened a confirmation'; end
end

$game_room_test_user = 'Alice'
app = TournamentAppDenialContract.new
assert(app.send(:invitation_account_guard).call, 'The denial fixture must start with an authenticated account')
game = Object.new
%w[tournament_match __tournament_match tournament match_ref].each do |key|
  [nil, false, {}, {'partial' => 'marker'}].each do |value|
    marked = {key => value}
    assert_equal(false, app.send(:save_current_game, marked, {}, game), "#{key}: marked table save reached I/O")
    assert_equal(false, app.send(:save_current_game, {}, marked, game), "#{key}: marked session save reached I/O")
    assert_equal(nil, app.send(:create_saved_game_table, marked), "#{key}: marked archive created a room")
    assert_equal(nil, app.send(:resume_saved_game_at_table, marked, Object.new), "#{key}: marked waiting room tried restoration")
  end
end
assert_equal(64, app.notices.length)
assert(app.notices.all? { |message| message == 'Tournament games cannot be saved or resumed from a saved game.' },
  'An explicit policy denial was misreported as a damaged archive or network error')
puts 'PASS tournament application denial: 64 direct calls, zero network/storage/game-loading/confirmation and specific player explanation'
