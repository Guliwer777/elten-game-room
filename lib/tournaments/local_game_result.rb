require_relative 'local_fixed_team_result'
require_relative 'local_game_moves'
require_relative 'local_individual_standings'
require_relative 'private_action_trace'
module GameRoomTournaments
  class LocalGameResult < LocalFixedTeamResult
    def self.receipt_fields(receipt = nil); LocalGameMoves.receipt_fields(receipt); end
    def self.valid_command_count?(count); LocalGameMoves.valid_command_count?(count); end
    def self.listed_action_required?; false; end
    def initialize(private_choices: nil, realtime_input: nil, **options)
      @private_choices = private_choices
      @realtime_input = realtime_input
      super(**options)
    end
    def self.command_matches?(selection, command); LocalGameMoves.command_matches?(selection, command); end
    def self.validate_game_selection!(game, replay, user, receipt, **context)
      LocalGameMoves.validate_game_selection!(game, replay, user, receipt, **context)
    end
    def self.summary(execution, core, registry:, result_policy: nil)
      result = nil
      with_core(core, execution, owner: core['owner']) do |_tx, _transport, _table, repository, session|
        snapshot = repository.snapshot_for(session, force_events: true)
        game = registry.build(execution['request']['game_id'])
        replay = game.replay(snapshot.session, snapshot.events, repository)
        raise C::Blocked, :game_not_finished unless replay.finished?
        raise C::Blocked, :invalid_history unless replay.accepted_events.size == snapshot.events.size
        result = GameResult.from_replay(game: game, replay: replay, players: execution['request']['players'],
          options: execution['target']['native']['options'], event_count: snapshot.events.size, result_policy: result_policy)
      end
      result
    end
    def status
      @port.transaction do |document|
        execution = execution!(document)
        value = Data.copy(status_in(document, execution))
        if execution['start']
          core = core!(document, execution)
          user = @request['players'].find { |person| person['account'] == actor }.fetch('username')
          self.class.with_core(core, execution, owner: user) do |_tx, _transport, _table, repository, session|
            snapshot = repository.snapshot_for(session, force_events: true)
            game = @registry.build(@request['game_id'])
            replay = game.replay(snapshot.session, snapshot.events, repository)
            context = view_context(game, session, core['owner'], execution['start']['table_id'])
            game.prepare_view(replay, user, context: context)
            value['phase_label'] = game.turn_announcement(replay, user)
            automatic = game.automatic_action(replay, user, context: context)
            value['actions'] = normalize_actions((automatic ? [automatic] : []) + game.legal_actions(replay, user, context: context))
            value['action_labels'] = value['actions'].map { |selection| game.tournament_move_label(selection, replay: replay, viewer: user) }
          end
        end
        value['result'] = execution['result']
        value['finished'] = value['phase'] == 'finished'
        rows = document['executions'].values.select { |e| e['record_intent'] == execution['record_intent'] && e['result'] }
        record = document['records'].fetch(execution['record_intent'])
        standings_class = record['evidence']['version'] == 2 ? LocalFixedTeamStandings : LocalIndividualStandings
        table = standings_class.build(record: record, executions: rows)
        value['results'], value['standings'] = table.values_at('results', 'standings')
        detached(value)
      end
    end
    # A transient, actor-owned surface projection. Never persisted in public receipts.
    def surface
      @port.transaction do |document|
        execution = execution!(document)
        raise C::Blocked, :start_required unless execution['start']
        core = core!(document, execution)
        user = @request['players'].find { |person| person['account'] == actor }.fetch('username')
        self.class.with_core(core, execution, owner: user) do |_tx, _transport, _table, repository, session|
          snapshot = repository.snapshot_for(session, force_events: true)
          game = @registry.build(@request['game_id'])
          replay = game.replay(snapshot.session, snapshot.events, repository)
          game.prepare_view(replay, user, context: view_context(game, session, core['owner'], execution['start']['table_id']))
          return {spec: game.surface_spec(replay, user), revision: self.class.revision(execution, core['entries'])}.freeze
        end
      end
    end
    def realtime_view
      @port.transaction do |document|
        execution = execution!(document)
        raise C::Blocked, :start_required unless execution['start']
        core = core!(document, execution)
        user = @request['players'].find { |person| person['account'] == actor }.fetch('username')
        self.class.with_core(core, execution, owner: user) do |_tx, _transport, table, repository, session|
          snapshot = repository.snapshot_for(session, force_events: true)
          game = @registry.build(@request['game_id'])
          raise C::Blocked, :invalid_action unless game.tournament_execution_kind == :realtime
          return {viewer: user, table: Data.copy(table), session: Data.copy(snapshot.session),
            replay: game.replay(snapshot.session, snapshot.events, repository)}.freeze
        end
      end
    end
    private
    def normalize_actions(actions)
      actions.map { |action| GameSelection.encode(action.is_a?(Hash) ? action : action.to_h) }
    end
    def status_actions(_game, _replay, _user); []; end
    def runner_selection(selection); GameSelection.decode(selection); end
    def view_context(game, session, owner, table_id)
      context = action_context
      context.hidden_submissions = @private_choices
      context.now = GameRoomSessionClock.new.public_send(game.precise_action_clock? ? :now_f : :now, session)
      context.session_id = session['__id']
      context.table_id = table_id
      context.table_owner = owner
      context.options = game.options_from_json(session['options'])
      context
    end
    def action_context
      GameRoomGames::ActionContext.new(random_source: MoveRandomness.new, local_data: @realtime_data || {}, hidden_submissions: @private_trace || @private_choices)
    end
    def context_receipt(context)
      value = {'randomness' => context.random_source.rolls, 'action_time' => context.now}
      value['realtime_input'] = @realtime_input.to_h if @realtime_data
      if @private_input && @private_trace
        @private_input = @private_choices.prepare(session_id: @private_choices.session_id,
          round_id: @private_round, user: actor, payload: {'selection' => @private_selection, 'calls' => @private_trace.calls})
      end
      value['selection_ref'] = @private_input.commitment if @private_input
      value
    end
    def prepare_input!(id, selection, game, execution:, session:, table:)
      @private_input = nil
      @private_trace = nil
      @realtime_data = nil
      if game.tournament_execution_kind == :realtime && selection['action'] == game.tournament_realtime_point_action
        raise C::Blocked, :invalid_action unless @realtime_input.instance_of?(RealtimePointInput)
        @realtime_data = RealtimePointInput.validate!(@realtime_input.to_h, request: @request, game: game, selection: selection,
          native_uuid: table['__live_session_id'], table_id: table['__id'], session_id: session['__id'],
          control_epoch: session['__control_epoch'])
      elsif @realtime_input
        raise C::Blocked, :invalid_action
      end
      return unless game.tournament_private_protocol?
      raise C::Blocked, :private_choices_required unless @private_choices
      @private_round, @private_selection = LocalPrivateChoices.input_round(id), selection
      @private_input = @private_choices.prepare(session_id: @private_choices.session_id,
        round_id: @private_round, user: actor, payload: {'selection' => selection})
      @private_trace = PrivateActionTrace.new(@private_choices)
    end
    def receipt_selection(selection)
      @private_input ? {'kind' => 'private', 'action' => 'submitted'} : selection
    end
    def same_input?(receipt, selection)
      return super unless receipt.key?('selection_ref')
      value = @private_choices && @private_choices.reveal(session_id: receipt['session_id'],
        round_id: LocalPrivateChoices.input_round(receipt['id']), user: actor, commitment: receipt['selection_ref'])
      value && value.payload['selection'].eql?(selection)
    end
    def runner_options(context)
      {action_context_observer: ->(actual) { context.now = actual.now }}
    end
  end
end
