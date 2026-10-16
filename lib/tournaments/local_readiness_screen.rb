# encoding: UTF-8
require_relative '../game_room_background'

module GameRoomTournaments
  # Tylko prezentacja lokalnego pionu K03; Work jest opróżniany z istniejącego
  # update formularza. Nie ma timera, pętli I/O, pollingu backendu ani retry.
  module LocalReadinessScreen
    using GameRoomLocalization::Translations
    private

    def local_readiness?
      @workspace.respond_to?(:readiness_session) && !@workspace.readiness_session.nil?
    end

    def build_readiness_controls(details, refresh_button, now, back)
      @local_targets = ListBox.new([], header: text(_("Accepted local matches — historical readback")), quiet: true)
      @readiness_operations = ListBox.new([], header: text(_("Readiness operations")), quiet: true)
      prepare = button(_("Prepare local test plan")) { start_readiness(:prepare) }
      ready = button(_("Ready")) { declare_local_readiness('ready') }
      withdraw = button(_("Withdraw readiness")) { declare_local_readiness('withdrawn') }
      check = button(_("Check uncertain operation")) { reconcile_local_readiness }
      history = button(_("Read selected local record")) do
        item = @readiness_state && @readiness_state[:targets][@local_targets.index]
        start_readiness(:inspect, target: item[:target]) if item
      end
      make_form([@tournaments, @matches, @status, details, refresh_button, prepare, ready, withdraw,
        @local_targets, history, @readiness_operations, check, now, back], cancel: back)
      @form.readiness_tick = method(:drain_readiness)
      # Escape/Back unieważnia kontekst również podczas workera, ale nie modalu.
      back.on(:press) { finish if @readiness_pending && !@busy && !@finished }
      @matches.on(:move) { interaction(restore: false) { start_readiness(:inspect) } }
    end

    def start_readiness(action, **options)
      return if @readiness_pending || !current?
      match = @controller.view[:matches][@matches.index]
      if [:prepare, :accept, :declare].include?(action) && local_readiness_refusal
        @status.set_text(local_readiness_status)
        @explanation = true
        return
      end
      return unless match || options[:target] || action == :inspect
      if action == :inspect && !options[:target] && local_readiness_refusal
        options[:target] = @readiness_state[:target] if @readiness_state
      end
      @readiness_work ||= GameRoomBackground::Work.new(runtime: @program.class.app_runtime)
      # Kopia danych UI przed uruchomieniem; obiekty ScheduleCandidate są immutable.
      match_id = match && match.fetch('match_id').dup.freeze
      @readiness_pending = {action: action, target: options[:target], match_id: match_id,
        tournament_id: selected_id, field_index: @form.index,
        positions: @form.fields.grep(EditBox).map { |field| [field, field.index, field.check] }}.freeze
      @readiness_state = nil if action == :inspect && !options[:target]
      @status.set_text(local_readiness_status)
      started = @readiness_work.start { @controller.readiness(action: action, match_id: match_id, **options) }
      raise 'Worker gotowości nie przyjął pojedynczej akcji' unless started
    rescue Exception
      @readiness_pending = nil
      raise
    end

    def drain_readiness
      return if @busy || !@readiness_pending || !current?
      outcome = @readiness_work.take
      return unless outcome
      pending, @readiness_pending = @readiness_pending, nil
      interaction(restore: false) do
        restore_readiness_selection(pending)
        value, error = outcome
        if error
          if (LocalWorkspace::OPERATION_ERRORS + [ReadinessContract::Blocked, ReadinessContract::PortUnavailable,
              ReadinessJournal::Corrupt, ReadinessJournal::Uncertain]).any? { |type| error.is_a?(type) }
            @readiness_state = {state: :unknown, reason: :storage_unavailable, current: nil, records: [], targets: [], target: nil}.freeze
          else
            raise error, cause: error.cause
          end
        elsif pending[:action] == :prepare && value[:state] == :prepared
          prepared = value.fetch(:candidate)
          if show_local_plan(prepared) && current?
            # Resume modalu pompuje callbacki. Nowy pending musi przejąć wybór
            # sprzed przygotowania, nie przestawione w tym czasie kursory.
            restore_readiness_selection(pending)
            start_readiness(:accept, prepared: prepared)
          else
            present_readiness if current?
            restore_readiness_selection(pending) if current?
          end
          return
        else
          if !value[:operation] && @readiness_state && value[:target] && value[:target] == @readiness_state[:target]
            value = value.merge(operation: @readiness_state[:operation]).freeze
          end
          @readiness_state = value
          @historical_target = pending[:target]
        end
        present_readiness if current?
        restore_readiness_selection(pending) if current?
      end
    end

    def restore_readiness_selection(pending)
      index = @controller.view[:tournaments].index { |row| row['__id'] == pending[:tournament_id] }
      @tournaments.index = index if index && current?
      index = @controller.view[:matches].index { |row| row['match_id'] == pending[:match_id] }
      @matches.index = index if index && current?
      pending[:positions].each do |field, caret, check|
        break unless current?
        field.index, field.check = caret, check
      end
      @form.index = pending[:field_index] if current?
    end

    def present_readiness
      return unless @readiness_state
      targets = @readiness_state.fetch(:targets, [])
      @local_targets.update_options(targets.map do |item|
        text(_("Local plan %{plan}: %{match}")) % {plan: item[:plan_id], match: match_text(item[:match])}
      end, keys: targets.map { |item| [item[:plan_id], item[:match]['match_id']] })
      return unless current?
      records = @readiness_state.fetch(:records, [])
      @readiness_operations.update_options(records.map do |record|
        text(_("Operation %{id}: %{state}; declaration: %{declaration}")) % {
          id: record['operation']['operation_id'], state: operation_state_text(record['status']),
          declaration: readiness_value_text(record['operation']['request']['availability'])}
      end, keys: records.map { |record| record['operation']['operation_id'] })
      @status.set_text(local_readiness_status) if current?
      @form.game_room_general_help_tips = [text(_("Check status only reads. Prepare local test plan opens the full local trial for explicit acceptance. Ready and Withdraw readiness each declare one decision. Check uncertain operation only reads the selected original UUID; it never sends again. Historical records remain available after reopening. Back cancels presentation, not a write already in progress."))]
    end

    def declare_local_readiness(availability)
      if @historical_target || !@readiness_state || !@readiness_state[:current]
        @readiness_notice = text(_("Read the selected current match first. Historical readback does not authorize a new declaration."))
        @status.set_text(local_readiness_status)
        return
      end
      @readiness_notice = nil
      start_readiness(:declare, availability: availability, expected_revision: @readiness_state[:current]['ready_revision'])
    end

    def reconcile_local_readiness
      record = @readiness_state && @readiness_state.fetch(:records, [])[@readiness_operations.index]
      return unless record
      start_readiness(:reconcile, target: @readiness_state[:target], operation_id: record['operation']['operation_id'])
    end

    def readiness_value_text(value)
      case value
      when 'ready' then text(_("ready"))
      when 'withdrawn' then text(_("withdrawn"))
      else text(_("unknown"))
      end
    end

    def operation_state_text(value)
      case value.to_s
      when 'confirmed' then text(_("confirmed"))
      when 'refused' then text(_("refused"))
      when 'conflict' then text(_("conflict"))
      when 'blocked' then text(_("blocked"))
      when 'unsupported' then text(_("unsupported"))
      when 'prepared', 'attempted', 'pending' then text(_("uncertain — check the original operation"))
      else text(_("unknown"))
      end
    end

    # Ta sama mapa powodów co D1; zatrzymany stary widok nie daje prawa do zapisu.
    def local_readiness_refusal
      return entry_reason_text unless @controller.reason == :candidate
      return entry_reason_text(:not_read) unless @controller.view[:candidate] && @controller.view[:matches][@matches.index]
      nil
    end

    def local_readiness_status
      lines = [text(_("Local test — this computer only")), text(_("Test actor: %{actor}")) % {actor: @workspace.actor}]
      refusal = local_readiness_refusal
      lines << refusal if refusal
      if @readiness_pending
        lines << text(_("Local readiness operation in progress. Back discards its presentation, not its durable intent."))
      elsif @readiness_state && @readiness_state[:current]
        lines << text(_("Own readiness: %{state}; revision: %{revision}")) % {
          state: readiness_value_text(@readiness_state[:current]['state']), revision: @readiness_state[:current]['ready_revision']}
        lines << text(_("Accepted local plan: %{plan}")) % {plan: @readiness_state[:plan_id]}
      elsif @readiness_state && [:blocked, :unknown].include?(@readiness_state[:state])
        lines << text(_("The local result cannot be confirmed. Data has not been replaced. Read the original operation; do not send again."))
      elsif !refusal
        lines << text(_("No local test plan has been accepted for this match. Check status, then explicitly prepare and accept the complete local plan."))
      end
      effect = @readiness_state && @readiness_state[:operation]
      if effect
        lines << text(_("Operation result: %{state}; original UUID: %{id}")) % {
          state: operation_state_text(effect[:state]), id: effect[:operation_id] || text(_("unknown"))}
      end
      lines << @readiness_notice if @readiness_notice
      lines << text(_("Readiness is not an invitation, consent or start. Game roles, teams and scoring are unassigned. Propose playing now and starting matches are unavailable."))
      lines.join("\r\n")
    end

    def local_plan_text(candidate)
      data = candidate.to_h
      lines = [text(_("WARNING: local trial only, not a server seal. Acceptance saves an immutable full local plan. It does not assign game roles, teams, starting seats or scoring and cannot start a match.")),
        text(_("Full registered roster: %{players}")) % {players: data.fetch('roster').join(', ')},
        text(_("Game: %{game}")) % {game: data.fetch('game_id')},
        text(_("Options: %{options}")) % {options: data.fetch('game_options').to_json},
        text(_("Windows: %{windows}")) % {windows: data.fetch('windows').to_json},
        text(_("Schedule candidate: %{id}")) % {id: data.fetch('schedule_id')}]
      lines.concat(data.fetch('matches').map { |match| match_text(match) })
      lines.join("\r\n")
    end
  end
end
