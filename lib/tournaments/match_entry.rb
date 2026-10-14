# encoding: UTF-8
require_relative 'entry_context'

module GameRoomTournaments
  # Odczyt zapisów i całego kandydata; filtrowanie dopiero po obliczeniu planu.
  class MatchEntry
    using GameRoomLocalization::Translations
    attr_reader :view, :context, :reason, :readback_result

    def initialize(workspace:, context:, request: nil, readback: nil)
      if (request || readback) && !(request.instance_of?(CoordinationRequest) && readback.respond_to?(:call))
        raise ArgumentError, 'Odczyt koordynacji wymaga pierwotnego request i jawnego portu'
      end
      @request, @readback = request, readback
      @workspace, @context = workspace, context
      @readiness_mutex = Mutex.new
      @closed = false
      @actor = Publication::Data.account(workspace.actor).downcase.freeze
      @reason = :not_read
      @view = {tournaments: [].freeze, matches: [].freeze, candidate: nil, selected_id: nil}.freeze
    end

    def refresh(selected_id: nil)
      lease = @context.capture
      return unless @context.current?(lease)
      return read_history(lease) if @request
      snapshot = @context.with_runtime(lease) { @workspace.entry_load(context: @context, lease: lease) }
      return unless @context.current?(lease)
      return failed_read unless snapshot
      begin
        # Ta sama bramka co dla kandydata, także gdy konflikt usunął członkostwo.
        ScheduleSource.validate_diagnostics!(snapshot)
      rescue Publication::Invalid => error
        raise unless error.code == :unresolved_source_diagnostics
        @reason = error.code
        return @view
      end
      ids = snapshot.fetch('members').select { |member| member.fetch('account') == @actor }.map { |member| member.fetch('tournament_id') }
      rows = snapshot.fetch('announcements').select { |row| ids.include?(row.fetch('__id')) }
      selected = rows.find { |row| row.fetch('__id') == selected_id } || rows.first
      candidate = nil
      reason = :no_membership
      if selected
        candidate = @context.with_runtime(lease) do
          @workspace.schedule_candidate(publication_ref: {
            'author' => selected.fetch('__insertion_user'), 'publication_key' => selected.fetch('publication_key')},
            context: @context, lease: lease)
        end
        return unless @context.current?(lease)
        return failed_read unless candidate
        if candidate.is_a?(ScheduleCandidate)
          candidate = candidate.to_h
          reason = :candidate
        else
          reason = candidate.fetch(:reason)
          candidate = nil
          if [:unresolved_source_diagnostics, :missing_publication].include?(reason)
            @reason = reason
            return @view
          end
        end
      end
      matches = candidate ? candidate.fetch('matches').select { |match| match.fetch('players').include?(@actor) } : []
      @reason = reason
      @view = {tournaments: rows.freeze, matches: matches.freeze, candidate: candidate,
        selected_id: selected && selected.fetch('__id')}.freeze
    end

    def read_history(lease)
      if @context.coordination_context(request: @request) == :context_unavailable
        @readback_result = {state: :coordination_unavailable, reason: :context_unavailable, operation_id: nil, binding: nil}.freeze
      else
        result = @context.with_runtime(lease) do
          EltenAPI::Tasks.run(title: GameRoomContent.utf8(_("Checking original match coordination")), ui: :none, cancellable: false) do
            @readback.call(request: @request) if @context.current?(lease)
          end
        end
        return unless result && @context.current?(lease)
        @readback_result = result
      end
      @reason = :history
      @view
    end
    private :read_history

    def failed_read
      @reason = :read_failed
      @view
    end
    private :failed_read

    # Dane zwrotne przejmuje UI dopiero pod pierwotnym lease. Worker nie zmienia view.
    def readiness(action:, match_id:, **options)
      lease = @context.capture
      raise ReadinessContract::Blocked, :context_changed unless @context.current?(lease)
      connection = @readiness_mutex.synchronize { @readiness_connection unless @closed }
      unless connection
        created = @workspace.readiness_connection(context: @context, lease: lease)
        connection = @readiness_mutex.synchronize do
          @readiness_connection ||= created unless @closed
        end
        created.close unless connection.equal?(created)
        raise ReadinessContract::Blocked, :context_changed unless connection
      end
      connection.perform(action: action, candidate: @view[:candidate], match_id: match_id, **options)
    end

    # Bez jawnego sandboxa dawne wejście nie autoryzuje żadnego zapisu.
    def declare_ready
      :context_unavailable
    end

    def propose_now
      :context_unavailable
    end

    def close
      connection = @readiness_mutex.synchronize do
        @closed = true
        value, @readiness_connection = @readiness_connection, nil
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
          raise primary, cause: primary.cause if primary
        end
      end
    end
  end
end
