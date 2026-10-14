# encoding: UTF-8
require_relative 'local_fixed_team_start'
require_relative '../game_session_runner'
require_relative '../game_random'

module GameRoomTournaments
  class LocalFixedTeamMoves < LocalFixedTeamStart
    C = CoordinationContract
    Data = Publication::Data
    MAX_MOVES = 256
    FIELDS = %w[version kind id account binding_digest epoch native_uuid table_id session_id created_at revision selection record].freeze

    def self.receipt_fields(_receipt = nil); FIELDS; end
    def self.valid_command_count?(count); count == 1; end
    def self.listed_action_required?; true; end
    def self.command_matches?(selection, command)
      expected = case selection['action']
      when 'deal' then ['deal', command['value']]
      when /\Abid_\d+\z/ then ['bid', selection['bid'].to_s]
      when 'select' then ['play', selection['card']]
      end
      expected == command.values_at('action', 'value')
    end
    def self.validate_game_selection!(_game, _replay, _user, _receipt, **_context); end

    def self.revision(execution, records)
      C.digest({'session_id' => execution['start']['session_id'], 'epoch' => execution['start']['epoch'],
        'binding_digest' => execution['start']['binding_digest'], 'stack' => records})
    end

    def self.actions(game, replay, user)
      automatic = game.automatic_action(replay, user)
      (automatic ? [automatic] : []) + game.legal_actions(replay, user)
    end

    def self.validate!(execution, core, registry:, private_reader: nil)
      moves = execution.key?('moves') ? execution['moves'] : []
      unless moves.is_a?(Array) && moves.size <= MAX_MOVES && (moves.empty? || execution['start'])
        raise Publication::Invalid, :sandbox_corrupt
      end
      return if moves.empty?
      start = execution['start']
      ids = []
      event_ids = []
      prefix = start['records'].dup
      event_offset = 0
      moves.each_with_index do |receipt, index|
        C.fields!(receipt, receipt_fields(receipt))
        expected = start.slice('binding_digest', 'epoch', 'native_uuid', 'table_id', 'session_id').merge('version' => 1, 'kind' => 'move')
        person = execution['request']['players'].find { |p| p['account'] == receipt['account'] }
        unless person && expected.all? { |key, value| receipt[key].eql?(value) } &&
            receipt['revision'] == revision(execution, prefix) && Data.integer?(receipt['created_at']) &&
            receipt['created_at'] >= (moves[index - 1] && index.positive? ? moves[index - 1]['created_at'] : start['created_at']) &&
            receipt['created_at'] < execution['request']['window']['closes']
          raise Publication::Invalid, :sandbox_corrupt
        end
        Data.text!(receipt['id'], bytes: 256)
        raise Publication::Invalid, :sandbox_corrupt if ids.include?(receipt['id'])
        ids << receipt['id']
        row = receipt['record']
        C.fields!(row, %w[seq message_id sender sender_id packet created_at])
        C.fields!(row['packet'], %w[version kind actor data])
        unless row['seq'].eql?(4 + index) && row['sender'].eql?({'user' => person['username']}) &&
            row['sender_id'] == core['participants'].fetch(person['account'])['id'] &&
            row['packet'].slice('version', 'kind', 'actor').eql?({'version' => GameRoomLiveSessionStore::PROTOCOL,
              'kind' => 'game_action', 'actor' => person['username']}) && Data.integer?(row['created_at'], 1)
          raise Publication::Invalid, :sandbox_corrupt
        end
        Data.text!(row['message_id'], bytes: 256)
        raise Publication::Invalid, :sandbox_corrupt if JSON.generate(row['packet']).bytesize > core['stack_entry_bytes']
        payload = row['packet']['data']
        C.fields!(payload, %w[session_id sequence controller control_epoch events])
        unless payload['session_id'].eql?(start['session_id']) && payload['sequence'].eql?(event_offset) &&
            payload['controller'].equal?(false) && payload['control_epoch'].eql?('initial') &&
            payload['events'].is_a?(Array) && valid_command_count?(payload['events'].size)
          raise Publication::Invalid, :sandbox_corrupt
        end
        payload['events'].each do |command|
        C.fields!(command, %w[action value move_id])
        GameRoomEventProtocol.validate_commands!([command.slice('action', 'value')])
        Data.text!(command['move_id'], bytes: 256)
        raise Publication::Invalid, :sandbox_corrupt if event_ids.include?(command['move_id'])
        event_ids << command['move_id']
        selection = receipt['selection']
        raise Publication::Invalid, :sandbox_corrupt unless selection.is_a?(Hash)
        raise Publication::Invalid, :sandbox_corrupt unless command_matches?(selection, command)
        end
        event_offset += payload['events'].size
        prefix << row
      end
      # The native protocol validates sender/session/epoch. The real game's
      # replay also has to accept every command; rejected events are corruption.
      with_core(core, execution, owner: core['owner']) do |_tx, transport, table, repository, session|
        snapshot = repository.snapshot_for(session, force_events: true)
        raise Publication::Invalid, :sandbox_corrupt unless snapshot && snapshot.events.size == event_offset
        game = registry.build(execution['request']['game_id'])
        offset = 0
        moves.each do |receipt|
          count = receipt['record']['packet']['data']['events'].size
          before = game.replay(snapshot.session, snapshot.events.take(offset), repository)
          user = receipt['record']['sender']['user']
          private_input = private_reader && private_reader.call(execution, receipt)
          selection = private_input ? private_input[:selection] : receipt['selection']
          unless (!listed_action_required? || actions(game, before, user).include?(selection)) &&
              snapshot.events.slice(offset, count).all? { |event| event['__insertion_user'] == user }
            raise Publication::Invalid, :sandbox_corrupt
          end
          validate_game_selection!(game, before, user, receipt, session: snapshot.session, owner: core['owner'],
            selection: selection, hidden_submissions: private_input && private_input[:vault], request: execution['request'])
          offset += count
        end
        replay = game.replay(snapshot.session, snapshot.events, repository)
        raise Publication::Invalid, :sandbox_corrupt unless replay.accepted_events.size == snapshot.events.size
      end
    rescue ArgumentError, C::Blocked => error
      raise Publication::Invalid.new(:sandbox_corrupt), cause: error
    end

    def self.with_core(core, execution, owner:, move: false, require_session: true)
      provider = LocalFixedTeamNativeProvider.new
      state = {'creates' => [], 'cores' => [core]}
      if core['closed']
        raise C::Blocked, :game_finalized if move
        # A disposable archive projection cannot mutate the closed stored core.
        state['cores'] = [Data.copy(core, max_bytes: LocalFixedTeamExecutionStorage::MAX_BYTES,
          max_nodes: LocalFixedTeamExecutionStorage::MAX_NODES, max_depth: 24).merge('closed' => false)]
      end
      tx = move ? provider.open_for_move(state: state, actor: owner, native_uuid: core['id'],
        session_id: execution['start']['session_id'], after: core['last_seq']) : provider.open(state: state, owner: owner)
      transport = primary = nil
      begin
        transport = GameRoomTransport.new(tx.program, **tx.transport_options)
        transport.start
        table = transport.room_snapshot(execution['target']['binding']['table_id'], force: true)&.fetch(:table)
        raise C::Blocked, :native_target_mismatch unless table && table['__live_session_id'] == core['id']
        repository = GameRepository.new(tx.program, transport: transport)
        session = repository.session_for_table(table, force: true)
        if require_session
          raise C::Blocked, :start_required unless session && execution['start'] && session['__id'] == execution['start']['session_id']
        end
        yield tx, transport, table, repository, session
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          transport&.close_local_view
        ensure
          begin
            tx.close
          ensure
            raise primary, cause: primary.cause if primary
          end
        end
      end
    end

    def move(operation_id:, revision:, selection:)
      Data.text!(operation_id, bytes: 256)
      Data.text!(revision, bytes: 256)
      selection = Data.copy(selection, max_bytes: 4096, max_nodes: 128, max_depth: 8)
      @record_reader.call(true)
      @port.transaction do |document|
        @record_reader.call(true)
        execution = execution!(document)
        raise C::Blocked, :start_required unless execution['start']
        moves = execution['moves'] ||= []
        prior = moves.find { |r| r['id'] == operation_id }
        if prior
          raise C::Blocked, :operation_conflict unless prior['account'] == actor && prior['revision'] == revision && same_input?(prior, selection)
          next detached(prior)
        end
        playing!(execution)
        raise C::Blocked, :move_limit if moves.size >= MAX_MOVES
        core = core!(document, execution)
        raise C::Blocked, :stale_view unless revision == self.class.revision(execution, core['entries'])
        user = @request['players'].find { |p| p['account'] == actor }.fetch('username')
        self.class.with_core(core, execution, owner: user, move: true) do |tx, transport, table, repository, session|
          snapshot = repository.snapshot_for(session, force_events: true)
          game = @registry.build(@request['game_id'])
          replay = game.replay(snapshot.session, snapshot.events, repository)
          raise C::Blocked, :invalid_action if self.class.listed_action_required? && !self.class.actions(game, replay, user).include?(selection)
          prepare_input!(operation_id, selection, game, execution: execution, session: snapshot.session, table: table)
          context = action_context
          room = -> do
            data = transport.room_snapshot(table['__id'], force: true)
            GameRoomSessionContracts::RoomSnapshot.new(**data.slice(:table, :members, :bots, :observers)) if data
          end
          runner = runner_error = nil
          begin
            runner = GameRoomSessionRunner.new(program: tx.program, transport: transport, repository: repository,
              game: game, session: snapshot.session, table: table, owner: table['owner'], viewer: user,
              room_snapshot_provider: room, context: context, covered: -> { false }, **runner_options(context))
            # A bounded Tasks worker is the single executor for this transaction.
            # submit refreshes and validates the revision before action_for.
            result, inserted = runner.submit(session: snapshot.session, replay: replay, selection: runner_selection(selection), actor: user)
            raise C::Blocked, result unless result == :ok && inserted && self.class.valid_command_count?(inserted.size)
          rescue Exception => error
            runner_error = error
            raise error, cause: error.cause
          ensure
            begin
              runner&.close
            ensure
              raise runner_error, cause: runner_error.cause if runner_error
            end
          end
          updated = @storage.copy(tx.dump['cores'].first)
          receipt = execution['start'].slice('binding_digest', 'epoch', 'native_uuid', 'table_id', 'session_id').merge(
            'version' => 1, 'kind' => 'move', 'id' => operation_id, 'account' => actor, 'created_at' => @clock.call,
            'revision' => revision, 'selection' => receipt_selection(selection), 'record' => updated['entries'].last).merge(context_receipt(context))
          core.replace(updated)
          moves << receipt
          @record_reader.call(true)
          playing!(execution)
          @storage.write(document, receipt: receipt)
          # Wake the existing dispatcher only after a committed final move.
          # The game replay supplies completion; no game-specific winner rules.
          if document.key?('dispatch') && status_in(document, execution)['phase'] == 'finished'
            LocalDispatchEvents.publish(@storage.identity)
          end
          detached(receipt)
        end
      end
    rescue GameRoomSessionRunner::StaleView => error
      raise C::Blocked.new(:stale_view), cause: error
    end

    def status
      @port.transaction do |document|
        execution = execution!(document)
        status_in(document, execution)
      end
    end

    def status_in(document, execution)
        start = execution['start']
        value = {'receipt' => start, 'binding' => execution['target']['binding'], 'mode' => 'local_test'}
        if start
          core = core!(document, execution)
          user = @request['players'].find { |p| p['account'] == actor }.fetch('username')
          self.class.with_core(core, execution, owner: user) do |_tx, _transport, _table, repository, session|
            snapshot = repository.snapshot_for(session, force_events: true)
            game = @registry.build(@request['game_id'])
            replay = game.replay(snapshot.session, snapshot.events, repository)
            value.merge!('session_id' => session['__id'], 'players' => replay.players, 'phase' =>
              (replay.finished? ? 'finished' : (replay.state.is_a?(Hash) ? replay.state[:phase].to_s : 'playing')),
              'event_count' => snapshot.events.size, 'revision' => self.class.revision(execution, core['entries']),
              'current_player' => replay.current_player, 'viewer' => user,
              'actions' => status_actions(game, replay, user),
              'last_move' => (execution['moves'] || []).reverse.find { |r| r['account'] == actor })
          end
        end
        detached(value)
    end

    def read_move(operation_id:)
      Data.text!(operation_id, bytes: 256)
      @port.transaction do |document|
        execution = execution!(document)
        receipt = (execution['moves'] || []).find { |r| r['id'] == operation_id }
        raise C::Blocked, :operation_conflict if receipt && receipt['account'] != actor
        detached(receipt)
      end
    end

    private

    def status_actions(game, replay, user); self.class.actions(game, replay, user); end

    def action_context
      GameRoomGames::ActionContext.new(random_source: GameRoomRandom::LocalSecureSource.new, local_data: {})
    end
    def context_receipt(_context); {}; end
    def runner_options(_context); {}; end
    def same_input?(receipt, selection); receipt['selection'].eql?(selection); end
    def prepare_input!(_id, _selection, _game, **_context); end
    def runner_selection(selection); selection; end
    def receipt_selection(selection); selection; end

    def playing!(execution)
      raise C::Blocked, :game_finalized if execution['result']
      now = @clock.call
      raise C::Blocked, :invalid_clock unless Data.integer?(now)
      raise C::Blocked, :stale_grant unless execution['epoch'] == execution['start']['epoch']
      raise C::Blocked, :outside_window unless @request['window']['opens'] <= now && now < @request['window']['closes']
      actor
    end
  end
end
