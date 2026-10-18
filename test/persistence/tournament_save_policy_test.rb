require_relative '../support/saved_games_ui'

class UnexpectedTournamentSaveCall
  def method_missing(name, *)
    raise "Tournament denial performed an unexpected operation: #{name}"
  end
end

$game_room_test_user = 'Alice'
forbidden = UnexpectedTournamentSaveCall.new
use_case = GameRoomUseCases::SaveGame.new(repository: forbidden, transport: forbidden,
  archives: -> { raise 'Tournament denial opened archive storage' })
archive = GameRoomSavedGameArchive.new(forbidden, owner: 'Alice')
repository = GameRepository.allocate

%w[tournament_match match_ref __tournament_match tournament].each do |key|
  [nil, false, {}, {'bad' => 'marker'}].each do |value|
    marked = {key => value}
    assert(GameRoomTournamentMarker.present?(marked), "Incomplete #{key} permitted saving")
    assert_raises(GameRoomTournamentMarker::SavingDisabled) do
      use_case.call(table: marked, table_id: 1, session: {}, game: forbidden, intent: forbidden)
    end
    assert_raises(GameRoomTournamentMarker::SavingDisabled) do
      use_case.call(table: {}, table_id: 1, session: marked, game: forbidden)
    end
    assert_raises(GameRoomTournamentMarker::SavingDisabled) do
      archive.put(game: forbidden, table: marked, snapshot: Struct.new(:session).new({}), repository: forbidden)
    end
    assert_raises(GameRoomTournamentMarker::SavingDisabled) do
      archive.restored_data(marked, game: forbidden, table_id: 1)
    end
    assert_raises(GameRoomTournamentMarker::SavingDisabled) do
      repository.restore_session(table: marked, game: 'tic_tac_toe', players: %w[Alice Bob], options: '{}', restore: {})
    end
  end
end
assert(!GameRoomTournamentMarker.present?({}, nil), 'Ordinary table was classified as a tournament')
assert_raises(GameRoomTournamentMarker::SavingDisabled) do
  use_case.call(table: {}, table_id: 1, session: {}, game: forbidden, tournament: {})
end

# Native menu construction, not a source-string check. An already opened menu
# must recheck availability, and an ordinary table must retain Ctrl+S.
screen = GameScreen.allocate
table = {'__id' => 8, 'owner' => 'Alice'}
session = {'__id' => 9, 'options' => '{}'}
game = GameRoomGames::TicTacToe.new
{table: table, session: session, game: game, table_owner: 'Alice', save_game: ->(*) { raise 'Unexpected save' }}.each do |key, value|
  screen.instance_variable_set("@#{key}", value)
end
layout = GameRoomLayout::Screen.new(view_spec: GameRoomLayout::ViewSpec.new,
  user_items: RoomPresentation.user_rows(%w[Alice Bob], owner: 'Alice', players: %w[Alice Bob], active: true))
wait = Struct.new(:action, :replay).new(nil, Struct.new(:finished?).new(false))
screen.send(:bind_wait_participants, wait, layout, -> {})
menu = FakeMenu.new
layout.form.context(menu, false)
save = menu.options.find { |item| item[0] == 'Save the game and close the table' }
assert(save && save[2] == 's', 'Ordinary save lost its native Ctrl+S menu action')
table['tournament_match'] = {}
save[3].call
assert(wait.action.nil?, 'A stale menu dispatched a tournament save')
menu = FakeMenu.new
layout.form.context(menu, false)
assert(menu.options.none? { |item| item[0] == 'Save the game and close the table' }, 'Tournament menu still contains saving')
puts 'PASS tournament save policy: incomplete markers, use-case/archive/repository boundaries and native Ctrl+S menu availability'
