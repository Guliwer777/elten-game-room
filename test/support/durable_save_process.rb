# encoding: UTF-8
require_relative 'durable_save_fixture'
include DurableSaveFixture
mode, root = ARGV
DurableSaveFixture.root!(root)
if mode == 'A'
  h = DurableSaveFixture.room
  h.as('Alice') do
    before = h.replay('Alice')
    assert(before.state.nil? && before.accepted_events.size == 2, 'Błędne przygotowanie Czwórek')
    service = Resources.new(root)
    service.lost_reply = service.read_failure = true
    store = DurableSaveFixture.intent(root) if defined?(GameRoomSavedGameSaveIntent)
    service.intent = store
    archive = AccountSavedGames.new(program, owner: 'Alice', resources: service)
    use_case = DurableSaveFixture.use_case(h, archive)
    args = arguments(h)
    # Most wyłącznie pierwszego RED: stary kod wykonuje prawdziwy upload,
    # aby brak nowego kontraktu objawił się rollbackiem, nie błędem keyword.
    args[:intent] = store if store
    error = nil
    begin
      use_case.call(**args)
    rescue StandardError => exception
      error = exception
    end
    save_room(root,h)
    assert(service.state['uploads'] == 1 && !h.core.closed, 'Nie wykonano jednej niepewnej wysyłki')
    frozen = h.repositories['Alice'].snapshot_for(h.session, force_events: true).session
    assert(frozen['__frozen'], 'RED: trwała intencja po upload/lostreply/readfail utraciła freeze')
    assert(store, 'Nie wdrożono jawnego intentu')
    operation = store.list.fetch(0)
    assert(operation['status'] == 'uncertain', 'Nie zachowano niepewności')
    assert(error && error.cause && error.cause.message == 'Odpowiedź upload utracona', 'Zgubiono pierwotny błąd upload')
    begin
      use_case.call(**args)
      raise 'Ponowne call przyjęto'
    rescue GameRoomSavedGameSaveIntent::Pending
      assert(service.state['uploads'] == 1, 'Ponowiono upload')
    end
    dump(File.join(root,'A.json'), {'pid'=>Process.pid,'operation'=>operation,'board'=>before.board,
      'players'=>before.players,'current_player'=>before.current_player,'closed'=>h.core.closed})
  end
  puts 'PASS A: jedna wysyłka, trwały intent i zamrożenie bez close'
elsif mode == 'B'
  original = read(File.join(root,'A.json'))
  assert(original['pid'] != Process.pid, 'To nie jest zimny restart')
  h = load_room(root)
  h.as('Alice') do
    store = DurableSaveFixture.intent(root)
    raw_before = File.binread(store.path)
    operation = store.fetch(original.fetch('operation').fetch('id'))
    assert(operation == original['operation'] && File.binread(store.path) == raw_before, 'Restart nadpisał intent')
    service = Resources.new(root)
    archive = AccountSavedGames.new(program, owner: 'Alice', resources: service)
    use_case = DurableSaveFixture.use_case(h, archive)
    assert(!h.core.closed && h.repositories['Alice'].snapshot_for(h.session, force_events: true).session['__frozen'], 'Nie zachowano źródłowego stosu')
    row = use_case.reconcile(intent: store, id: operation['id'], game: h.game)
    assert(h.core.closed, 'Stary stół nie został zamknięty po potwierdzeniu')
    assert(store.fetch(operation['id'])['status'] == 'readback_confirmed', 'Brak trwałego potwierdzenia')
    assert(use_case.reconcile(intent: store, id: operation['id'], game: h.game) == row, 'Powtórne uzgodnienie zmieniło zapis')
    assert(service.state['uploads'] == 1, 'Zimny powrót ponowił upload')
    repo, transport = h.repositories['Alice'], h.transports['Alice']
    table = transport.create_room(name: 'Wznowione', game: h.game.id, owner: 'Alice', game_options: row['options'], resume_save_id: row['id'])
    bob = GameRoomTransport.new(ProgramDouble.new(h.broker.endpoint('Bob', fresh: true)))
    discovered = bob.discover_rooms.find { |r| r['__id'] == table['__id'] }
    h.as('Bob') { assert(bob.establish_membership(table_id: table['__id'], owner: 'Alice', capacity: 8, user: 'Bob', table: discovered), 'Bob nie dołączył') }
    restored = archive.restored_data(row, game: h.game, table_id: table['__id'], now: row['saved_at'] + 86_400)
    session = repo.restore_session(table: table, game: h.game.id, players: restored[:players], options: row['options'], restore: restored)
    snapshot = repo.snapshot_for(session, force_events: true)
    replay = h.game.replay(snapshot.session, snapshot.events, repo)
    assert(replay.state.nil? && replay.board == original['board'] && replay.players == original['players'] && replay.current_player == original['current_player'], 'Zmieniono planszę/osoby/turę')
    assert(snapshot.events.map { |e| repo.event_id(e) } == row['events'].map { |e| e['id'] }, 'Zmieniono ID prefiksu')
    assert(GameRoomSessionClock.from_server(snapshot.session, snapshot.session['__server_started_at']) == row['game_time'], 'Przerwa zużyła czas gry')
    selection = h.game.legal_actions(replay,replay.current_player).first
    status, plan = h.game.action_for(selection,replay,replay.current_player)
    assert(status == :ok && plan, 'Brak dalszego ruchu')
    repo.append_events(session: session, sequence: repo.next_sequence(session,snapshot.events), events: plan.events, actor: replay.current_player)
    remote = GameRepository.new(ProgramDouble.new(h.broker.endpoint('Bob')), transport: bob, server_tables: {})
    remote_session = remote.session_for_table(discovered)
    remote_snapshot = remote.snapshot_for(remote_session,force_events: true)
    advanced = h.game.replay(remote_snapshot.session,remote_snapshot.events,remote)
    assert(advanced.accepted_events.size == 3 && advanced.board != replay.board, 'Zdalny replay nie przyjął trzeciego ruchu')
    dump(File.join(root,'B.json'), {'pid'=>Process.pid,'uploads'=>service.state['uploads'],'closed_old'=>h.core.closed,
      'events'=>advanced.accepted_events.size,'archive_id'=>row['id'],'status'=>store.fetch(operation['id'])['status']})
  end
  puts 'PASS B: zimne uzgodnienie tego samego UUID, close i dalszy ruch zdalny'
else
  raise 'Nieznany etap próby'
end
