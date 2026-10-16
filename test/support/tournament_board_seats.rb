# encoding: UTF-8
require_relative 'tournament_local_execution_plan'
require_relative '../../lib/tournaments/local_execution_plan_backend'
require_relative '../../lib/game_repository'

module TournamentBoardSeatsSupport
  include TournamentLocalExecutionPlanSupport

  class Fixture < TournamentLocalExecutionPlanSupport::Fixture
    def initialize(directory, options: {}, **settings)
      @board_options = options
      super(directory, **settings)
    end

    def draft(id = 'chess')
      value = super
      value.merge('game_options' => value['game_options'].merge(@board_options))
    end
  end

  def with_board(**settings)
    fixture = Fixture.new(Dir.mktmpdir('planszowe-', ENV.fetch('TMPDIR')), **settings)
    begin
      yield fixture
    ensure
      fixture.close
    end
  end

  # Odtworzenie modelu z rzeczywistego requestu A, bez tworzenia stołu/transportu.
  def check_board_model(value)
    game = GameRoomGames::CATALOG.build(value['game_id'])
    players = value['players'].sort_by { |p| p['seat'] }.map { |p| p['username'] }
    session = {'__players' => players, 'options' => JSON.generate(value['options'])}
    repository = GameRepository.new(nil, transport: Object.new)
    replay = game.replay(session, [], repository)
    assert_equal(players, replay.players, 'Rzeczywisty model zachowuje kolejność requestu')
    assert_equal(players.first, replay.current_player, 'Pierwsze miejsce rozpoczyna kontrolowany stan')
    case value['game_id']
    when 'four_in_a_row', 'tic_tac_toe'
      action = value['game_id'] == 'four_in_a_row' ? 'drop' : 'place'
      coordinates = action == 'drop' ? %w[1 2] : %w[1,1 2,1]
      events = players.each_with_index.map do |actor, index|
        {'__id' => index + 1, '__insertion_user' => actor, 'actor' => actor, 'action' => action, 'value' => coordinates[index]}
      end
      moved = game.replay(session, events, repository)
      assert_equal(events, moved.accepted_events, 'Natywne replay przyjmuje znaczniki obu miejsc')
      assert_equal([0,1], moved.board.first.first(2), 'Znaczniki są indeksami players, nie kolorami')
      assert_equal(%w[X O], moved.history.select { |h| h.kind == :move }.map(&:value)) if action == 'place'
    when 'checkers'
      assert_equal(value['options']['board_size'], replay.board.size)
      assert_equal('0m', replay.board.first.compact.first)
      assert_equal('1m', replay.board.last.compact.first)
      assert_equal([0,1], ['0m','1m'].map { |piece| game.send(:piece_owner, piece) })
      assert_equal(players, [replay.players[game.send(:piece_owner, '0m')], replay.players[game.send(:piece_owner, '1m')]])
    when 'reversi'
      assert_equal([0,1], [replay.board[3][4], replay.board[3][3]])
      assert_equal(players, [replay.players[replay.board[3][4]], replay.players[replay.board[3][3]]])
    when 'battleship'
      assert_equal(:placing, replay.state[:phase])
      assert_equal(players, replay.state[:shots].keys, 'Osobne mapy strzałów według prawdziwych graczy')
      assert_equal({}, replay.state[:fleets], 'Bez tworzenia lub ujawniania cudzej floty')
      assert_equal(value['options'], replay.state[:options])
    when 'mancala'
      assert_equal([0,1], players.map { |p| game.send(:side_of, replay.state, p) })
      assert_equal([6,13], [0,1].map { |side| game.send(:store_index, side) })
      assert_equal([0,0], [replay.state[:pits][6], replay.state[:pits][13]])
      assert_equal(value['options']['stones'], replay.state[:pits][0])
      assert_equal(value['options'], replay.state[:options])
    else
      raise 'Brak próby modelu tej rodziny'
    end
  end

  def without_board_write(path)
    before = File.exist?(path) ? File.binread(path) : nil
    writes = 0
    trace = TracePoint.new(:call) do |event|
      writes += 1 if event.defined_class == T::LocalExecutionPlanStorage && event.method_id == :write
    end
    begin
      trace.enable(target_thread: nil)
      yield
    ensure
      trace.disable
    end
    assert_equal(0, writes, 'Odmowa/odczyt bez wywołania zapisu')
    assert_equal(before, File.exist?(path) ? File.binread(path) : nil, 'Dokładne bajty magazynu bez zmian')
  end

  def publish_board(f, game, intent:, names: %w[Beta Alpha], options: {})
    f.now = 150
    settings = draft(game).merge('rematch' => true)
    settings['game_options'] = settings['game_options'].merge(options)
    result = f.author_service.publish(**params(game, draft: settings, intent_id: intent, timezone: 'local_test:system'))
    assert_equal('confirmed', result['status'])
    ref = {'author' => 'Organizator', 'publication_key' => result['values']['publication_key']}
    row = f.author_service.list['announcements'].find { |r| r['publication_key'] == ref['publication_key'] }
    names.each do |name|
      f.actor = name
      assert_equal('confirmed', f.service(f.journal_for(name)).join(tournament_id: row['__id'])['status'])
    end
    f.actor, f.now = 'Organizator', 201
    candidate = f.author_service.schedule_candidate(publication_ref: ref).to_h
    base = candidate['matches'].select { |m| m['leg'] == 1 }.to_h { |m| [m['match_id'], m['players'].reverse] }
    [ref, base]
  end
end
