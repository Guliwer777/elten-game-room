# encoding: UTF-8
require_relative 'tournament_fixed_team_execution'
require_relative 'tournament_fixed_team_native_service'
require_relative 'ft2_compatibility_trace'
require_relative '../../lib/tournaments/local_fixed_team_execution'
require_relative '../../lib/use_cases/accept_invitation'

module FT2CompatibilityBoundary
  include TournamentFixedTeamExecutionSupport

  class ResponseLost < StandardError; end
  class LosingProvider < TournamentFixedTeamNativeService
    attr_reader :failure, :receipt
    def initialize
      @failure = ResponseLost.new('Kontrolowana utrata odpowiedzi po wspólnym commit')
    end
    def committed(receipt:)
      @receipt = receipt
      raise @failure
    end
  end

  # Jawny port ODMOWY K06. Widzi rzeczywisty dysk oraz podłączone endpointy
  # testowego brokera, ale nigdy nie fabrykuje accepted ani prawa wejścia.
  class NoConsentPort
    attr_reader :calls, :online
    def initialize(path, players)
      @path, @calls = path, []
      raw = JSON.parse(File.binread(path))
      @broker = TournamentFixedTeamNativeService::Broker.new(raw['native'])
      @online = players.to_h { |p| [p, @broker.endpoint(p).user] }
    end
    def read_target(binding:, invitation_ref:, read_id:)
      state = JSON.parse(File.binread(@path))
      core = state['native']['cores'].find { |c| c['id'] == binding['native_uuid'] }
      raise 'Cel nie istnieje' unless core && core['invitations'].empty?
      response = {'status' => 'unknown', 'reason' => 'own_consent_missing'}
      @calls << {'binding' => binding, 'invitation_ref' => invitation_ref, 'read_id' => read_id,
        'online' => @online, 'native_core' => core, 'response' => response}
      response
    end
  end

  def disk_hex(directory)
    Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { |p| File.file?(p) }.sort.to_h do |p|
      [p.delete_prefix(directory + '/'), File.binread(p).unpack1('H*')]
    end
  end

  def state_path(context)
    File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
  end

  def check_no_start(state, target = nil)
    assert_equal(1, state['native']['creates'].size)
    assert_equal(1, state['native']['cores'].size)
    core = state['native']['cores'].first
    assert_equal({}, core['invitations'], 'Gotowość nie wysyła zaproszeń')
    assert_equal([core['owner'].downcase], core['participants'].keys, 'Pozostaje wyłącznie natywny twórca; brak automatycznego wejścia składu')
    assert_equal(['room_created'], core['entries'].map { |row| row['packet']['kind'] })
    if target
      assert_equal(nil, target['readback']['game_instance'])
      assert_equal(false, target['native']['start_allowed'])
      assert_equal(false, target['native']['dispatch_allowed'])
      assert_equal(core['id'], target['readback']['table']['__live_session_id'])
      assert_equal(target['binding']['table_id'], target['readback']['table']['__id'])
    end
    forbidden_keys = []
    walk = lambda do |value|
      case value
      when Hash
        value.each { |key, child| forbidden_keys << key if key.match?(/consent|entered/); walk.call(child) }
      when Array
        value.each { |child| walk.call(child) }
      end
    end
    walk.call(state)
    assert_equal([], forbidden_keys, 'Brak zapisanej zgody/wejścia')
  end

  def native_consumer(target, record)
    data = target['native']
    options = JSON.parse(target['readback']['table']['game_options'])
    players = data['options']['team_players']
    game = REGISTRY.build(target['binding']['game_id'])
    first = game.new_game_options(options)
    actual = game.options_for_team_roster(first, players: players)
    assignment = game.prepared_team_assignment(actual, players: players)
    assert_equal(data['options'], options)
    assert_equal(options, actual, 'Rzeczywisty consumer zachowuje cały natywny payload')
    assert(assignment, 'Gotowy skład bez nowego dialogu')
    assert_equal(options['team_seats'], assignment.seats)
    assert_equal(players, assignment.players)
    assert_equal(true, target['readback']['table']['private'])
    assert_equal(0, target['readback']['table']['bot_count'])
    assert_equal(record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }, players)
    {'input' => options, 'new_game_options' => first, 'actual' => actual,
      'players' => assignment.players, 'seats' => assignment.seats}
  end

  def deny_entry(context, record, result, trace:)
    binding = result[:binding]
    target = result[:target].to_h
    players = target['native']['options']['team_players']
    actor = players.last
    port = NoConsentPort.new(state_path(context), players)
    outcomes = []
    actor_backend(context, actor) do |_backend, authority, _directory, _session, _program, entry|
      lease = entry.capture
      reader = lambda do
        state = authority.call
        {'scope' => binding.to_h['scope'], 'account' => state['account'], 'runtime_id' => state['runtime_id'],
          'epoch' => entry.capture['epoch'], 'cancelled' => state['cancelled'] || !entry.current?(lease)}
      end
      guard = T::MatchTargetGuard.new(port: port, port_identity: 'ft2-compatibility-no-k06', context: reader)
      # Wyłącznie deskryptor hipotetycznej próby wejścia, nie wysłane zaproszenie.
      reference = {'app_invitation_id' => 1, 'native_invitation_id' => 'niewyslane',
        'generation' => 'hipotetyczna-proba', 'expires_at' => record['evidence']['plan']['matches'].first['windows'].first['closes'],
        'receipt_revision' => 'brak-k06'}
      invitation = Struct.new(:id, :table, :table_id).new(1, target['readback']['table'], target['readback']['table']['__id'])
      # consent() przechwytuje tylko lokalny zamiar. Nie zastępuje read_target/K06.
      token = guard.consent(binding: binding, invitation_ref: reference)
      assert(token, 'Poprawny lokalny zamiar pozwala dotrzeć do rzeczywistego portu odmowy')
      calls = []
      callbacks = GameRoomUseCases::InvitationMembership.new(**%i[pending complete establish reconnect leave apply_role revoke].to_h do |name|
        [name, ->(*_args, **_kwargs) { calls << name; raise 'Niedozwolony skutek membership' }]
      end)
      acceptance = GameRoomUseCases::AcceptInvitation.new(lobby: nil, transport: nil, invitations: nil,
        membership: callbacks, user: -> { actor }, target_guard: guard)
      check = {binding: binding, table: invitation.table, invitation_id: invitation.id, user: actor, invitation: invitation}
      trace.during('odmowy-guard-accept-reconnect') do
      assert_equal(:invalid_binding, guard.check(**check, consent: nil))
      assert_equal(:unconfirmed_target, guard.check(**check, consent: token))
      [nil, token].each do |consent|
        outcome = acceptance.join(invitation, current: nil, binding: binding, consent: consent)
        expected = consent ? :unconfirmed_target : :invalid_binding
        assert_equal(expected, outcome.result)
        assert_equal(false, outcome.left_current)
        assert_equal(false, acceptance.reconnect(invitation, binding: binding, consent: consent))
        outcomes << {'expected' => expected, 'actual' => outcome.result, 'left_current' => outcome.left_current}
      end
      unavailable = GameRoomUseCases::AcceptInvitation.new(lobby: nil, transport: nil, invitations: nil,
        membership: callbacks, user: -> { actor })
      assert_equal(:coordination_unavailable, unavailable.join(invitation, current: nil, binding: binding, consent: token).result)
      assert_equal([], calls)
      assert_equal(players, port.online.keys)
      assert_equal(3, port.calls.size, 'Guard oraz join/reconnect muszą dojść do read_target bez zgody')
      end
    end
    {'outcomes' => outcomes, 'port_calls' => port.calls, 'online' => port.online,
      'notice' => 'Token lokalnego zamiaru nie jest K06 accepted; wszystkie odpowiedzi portu unknown.'}
  end

  def positive_trace_control(trace)
    controls = []
    operation = lambda do
      broker = NativeLiveSessionsBroker.new
      names = %w[KontrolaA KontrolaB KontrolaC KontrolaD]
      Thread.current[:game_room_test_user] = names.first
      transports = names.to_h { |n| [n, GameRoomTransport.new(ProgramDouble.new(broker.endpoint(n)))] }
      owner = transports[names.first]
      options = REGISTRY.build('spades').with_team_assignment({'team_size' => 2}, players: names, seats: [0, 0, 1, 1])
      table = owner.create_room(name: 'Zwykla kontrola, nie turniej', game: 'spades', owner: names.first,
        game_options: JSON.generate(options), private_table: false, bot_count: 0)
      names.drop(1).each do |name|
        transport = transports[name]
        discovered = transport.discover_rooms.find { |r| r['__id'] == table['__id'] }
        transport.join_room(discovered, name)
      end
      owner.invite_user(table_id: table['__id'], user: 'KontrolaObserwator', metadata: {})
      repository = GameRepository.new(ProgramDouble.new(broker.endpoint(names.first)), transport: owner)
      game = repository.start_session(table: table, game: 'spades', players: names, options: JSON.generate(options))
      assert(game, 'Dodatni zwykły Start')
      core = broker.cores.fetch(table['__live_session_id'])
      assert(core.entries.any? { |r| r['packet']['kind'] == 'game_started' })
      controls << {'thread' => Thread.current.object_id, 'table' => table, 'game' => game, 'stack' => core.entries,
        'invitations' => core.invitations}
    ensure
      Thread.current[:game_room_test_user] = nil
    end
    trace.during('kontrola-zwykla-main-worker') do
      FT2CompatibilityTrace.marker
      operation.call
      trace.worker { FT2CompatibilityTrace.marker; operation.call }
    end
    rows = trace.rows.select { |r| r['phase'] == 'kontrola-zwykla-main-worker' }
    controls.each do |control|
      events = rows.select { |r| r['thread'] == control['thread'] }
      %w[marker invite_user invite start_session start_game].each { |method| assert(events.any? { |e| e['method'] == method }, "TracePoint nie widzi #{method}") }
      error = assert_raises(RuntimeError) { trace.check_empty(events) }
      assert(error.message.start_with?('RED_FT2A_C10:'), 'Oracle wykrywa realne zwykłe skutki')
    end
    {'controls' => controls, 'trace' => rows, 'workers' => trace.workers, 'notice' => 'Wyłącznie oddzielny broker RAM; ordinary Start nie nadaje praw turniejowych.'}
  end
end
