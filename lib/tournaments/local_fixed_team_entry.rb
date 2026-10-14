# encoding: UTF-8
require_relative 'entry_context'
require_relative 'local_readiness_session'

module GameRoomTournaments
  # Stan widoku przejmuje wyłącznie UI pod lease. Worker zwraca odłączone dane.
  class LocalFixedTeamEntry
    attr_reader :context, :view, :reason, :session
    def initialize(workspace:, context:, session:)
      @workspace, @context, @session = workspace, context, session
      @actor = Publication::Data.account(workspace.actor).downcase.freeze
      @mutex, @closed = Mutex.new, false
      @reason = :not_read
      @view = {tournaments: [], matches: [], selected_id: nil, records: [], current: nil}.freeze
    end

    def perform(action:, **options)
      lease = @context.capture
      raise ReadinessContract::Blocked, :context_changed unless @context.current?(lease)
      connection = @mutex.synchronize { @connection unless @closed }
      unless connection
        created = create_connection(lease)
        connection = @mutex.synchronize { @connection ||= created unless @closed }
        created.close unless connection.equal?(created)
        raise ReadinessContract::Blocked, :context_changed unless connection
      end
      action == :catalog ? connection.catalog : connection.perform(action: action, **options)
    end

    def adopt(value, selected_id: nil)
      if value[:state] == :read_failed
        @reason = value[:reason]
        return @view
      end
      if value.key?(:catalog)
        rows = value[:catalog].map do |record|
          {'__id' => record['preview']['intent_id'], 'title' => record['preview']['intent_id'], 'record' => record,
            'progress' => value.dig(:progress, record['preview']['intent_id'])}.freeze
        end.freeze
        row = rows.find { |r| r['__id'] == selected_id } || rows.first
        matches = row ? visible_matches(row['record']) : [].freeze
        @view = {tournaments: rows, matches: matches, selected_id: row && row['__id'], records: [], current: nil}.freeze
      else
        # Wynik/historyczny cel należą do pełnego wyboru, nie pozycji kursora.
        previous = value[:selection] == @view[:selection] ? @view : @view.merge(coordination: nil, operation: nil, admission: nil, local_game: nil,
          phase_preview: nil, phase_approval: nil, phase_execution_preview: nil, phase_execution: nil)
        @view = previous.merge(value).freeze
      end
      @reason = value[:reason]
      @view
    end

    def select_plan(id)
      rows = @view[:tournaments]
      row = rows.find { |r| r['__id'] == id }
      return unless row
      matches = visible_matches(row['record'])
      @view = {tournaments: rows, matches: matches, selected_id: id, records: [], current: nil}.freeze
    end
    def dispatch_update
      connection = @mutex.synchronize { @connection unless @closed }
      connection&.dispatch_update
    end

    def close
      connection = @mutex.synchronize do
        @closed = true
        value, @connection = @connection, nil
        value
      end
      primary = nil
      begin
        @context.close
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          connection&.close(primary: primary)
        ensure
          @session.close
          raise primary, cause: primary.cause if primary
        end
      end
    end

    private
    def visible_matches(record)
      organizer = record['preview']['source']['candidate']['publication_ref']['author'] == @actor
      record['evidence']['plan']['matches'].select { |m| organizer || m['players'].any? { |p| p['account'] == @actor } }.freeze
    end
    def create_connection(lease)
      @workspace.fixed_team_connection(context: @context, lease: lease, session: @session)
    end
  end
end
