require_relative 'coordination_request'
require_relative 'individual_native_payload'
require_relative '../game_session_clock'
require_relative '../game_session_runner'

module GameRoomTournaments
  # Active-UI client composition only. The caller supplies an authenticated
  # native snapshot; this object grants no admission, Start or write authority.
  # A changed table/session/roster closes the old client before any next input.
  class RealtimeMatchClient
    Data = Publication::Data
    Invalid = Publication::Invalid

    def initialize(program:, request:, native:, registry:, viewer:, snapshot:, services: {}, action_clock: nil)
      unless request.instance_of?(CoordinationRequest) && native.is_a?(FixedTeamNativePayload) && snapshot.respond_to?(:call)
        raise Invalid, :invalid_composition
      end
      @request, @native = request.to_h, native.to_h
      unless @native['request_digest'] == request.digest &&
          @native['players'] == @request['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
        raise Invalid, :record_mismatch
      end
      @viewer = Data.account(viewer)
      person = @request['players'].find { |person| person['account'] == @viewer.downcase }
      raise Invalid, :not_participant unless person
      @viewer = person['username']
      @game = registry.build(@request['game_id'])
      unless @game.tournament_execution_kind == :realtime && @game.tournament_realtime_point_action.is_a?(String)
        raise Invalid, :realtime_execution_required
      end
      @program, @snapshot, @services = program, snapshot, services.dup
      @action_clock = action_clock || ->(session) { GameRoomSessionClock.new.now(session) }
      @ui_thread = Thread.current
    end

    def start
      assert_ui!
      current = current!
      return true if @client
      @identity = identity(current)
      @client = @game.build_client(@program, **@services)
      raise Invalid, :realtime_execution_required unless @client
      @client.bind_screen(session_id: current[:session]['__id'], table_id: current[:table]['__id'],
        owner: current[:table]['owner'], viewer: @viewer, members: -> { @native['players'].dup })
      unless @client.start
        close
        return false
      end
      update(current)
      true
    rescue Exception
      close
      raise
    end

    def refresh
      assert_ui!
      raise Invalid, :start_required unless @client
      update(current!)
    end

    def attach_view(form, surface)
      refresh
      @client.attach_view(form, surface)
    end

    def detach_view
      assert_ui!
      @client&.detach_view
    end

    # A copied input from THIS client's agreed point, never a caller's point.
    # The existing Runner still owns validation and durable commit.
    def agreed_input
      assert_ui!
      raise Invalid, :start_required unless @client
      current = current!
      update(current)
      action = @game.tournament_realtime_point_action
      data = @client.context_data
      return nil unless data.is_a?(Hash) && data[action].is_a?(String)
      context_data = Data.copy({action => data[action]}, max_bytes: 256, max_nodes: 4, max_depth: 2)
      session, replay = current.values_at(:session, :replay)
      context = GameRoomGames::ActionContext.new(local_data: context_data, now: @action_clock.call(session),
        table_owner: current[:table]['owner'], table_id: current[:table]['__id'], session_id: session['__id'],
        options: @native['options'])
      selection = @game.automatic_action(replay, @viewer, context: context)
      return nil unless selection && selection['action'] == action
      status, plan = @game.action_for(selection, replay, @viewer, context: context)
      raise Invalid, :invalid_game_result unless status == :ok && plan.is_a?(GameRoomGames::ActionPlan)
      Data.freeze_tree(Data.copy({'request_digest' => @native['request_digest'],
        'table_id' => current[:table]['__id'], 'session_id' => session['__id'],
        'native_uuid' => current[:table]['__live_session_id'], 'control_epoch' => session.fetch('__control_epoch', 'initial'),
        'selection' => selection, 'local_data' => context_data}))
    end

    def close
      assert_ui!
      return if @closed
      @closed = true
      begin
        @client&.close
      ensure
        @client = @program = @snapshot = @services = @action_clock = nil
      end
    end

    # Copy agreed input to the existing executor's UI view. Its own worker,
    # leases and uncertain-write recovery remain the sole commit mechanism.
    def publish_agreed_input(runner:)
      assert_ui!
      raise Invalid, :invalid_composition unless runner.is_a?(GameRoomSessionRunner)
      input = agreed_input
      current = current!
      presentation = runner.presentation_snapshot
      unless presentation && identity(table: presentation.table, session: presentation.session) == @identity &&
          presentation.session['game'] == @request['game_id'] && presentation.replay.players == @native['players']
        raise Invalid, :native_target_mismatch
      end
      context = GameRoomGames::ActionContext.new(local_data: input ? Data.copy(input['local_data']) : {})
      runner.publish_view(session: current[:session], replay: current[:replay], busy: false, context: context)
      input
    end

    private

    def assert_ui!
      raise Invalid, :invalid_composition unless Thread.current.equal?(@ui_thread)
    end

    def identity(current)
      Data.freeze_tree(Data.copy([current[:table]['__id'], current[:table]['__live_session_id'], current[:session]['__id'],
        current[:table]['owner'], current[:session].fetch('__control_epoch', 'initial')]))
    end

    def current!
      raise Invalid, :local_view_closed if @closed
      value = @snapshot.call
      table, session, replay = value.is_a?(Hash) ? value.values_at(:table, :session, :replay) : []
      unless table.is_a?(Hash) && session.is_a?(Hash) && replay &&
          Data.integer?(table['__id'], 1) && Data.integer?(session['__id'], 1) &&
          table['__live_session_id'].is_a?(String) && !table['__live_session_id'].empty? &&
          table['game'] == @request['game_id'] && session['game'] == @request['game_id'] &&
          session['__table_owner'] == table['owner'] && @native['players'].include?(table['owner']) &&
          session['__players'] == @native['players'] && replay.players == @native['players'] &&
          JSON.parse(session['options']).eql?(@native['options']) &&
          JSON.parse(table['game_options']).eql?(@native['options']) &&
          session['__control_ready'] != false &&
          session.fetch('__controllers', {}).values.all? { |controller| controller == 'human' } &&
          (!@identity || identity(value) == @identity)
        raise Invalid, :native_target_mismatch
      end
      value
    rescue Exception
      close
      raise
    end

    def update(current)
      @client.update_table_control(current[:session]) if @client.respond_to?(:update_table_control)
      @client.before_wait(current[:replay], @viewer)
      current
    end
  end
end
