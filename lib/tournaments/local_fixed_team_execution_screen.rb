# encoding: UTF-8
require_relative 'match_entry_screen'
require_relative 'local_fixed_team_entry'
require_relative 'local_fixed_team_execution_ui_selection'
require_relative 'local_game_choice_dialog'
require_relative 'game_result'
require_relative 'local_match_labels'

module GameRoomTournaments
  # Oddzielne FT2; wspólna ochrona kontrolek, F1 i cleanup pochodzi z K03.
  class LocalFixedTeamExecutionScreen < MatchEntryScreen
    using GameRoomLocalization::Translations
    include LocalFixedTeamExecutionUISelection

    def run
      return if @running || @finished
      session = context = primary = nil
      begin
        unless @controller
          session = LocalReadinessSession.new
          session.choose_actor(@workspace.actor)
          context = EntryContext.new(program: @program, runtime: @program.class.app_runtime,
            owner_reader: @owner.method(:current), actor: @workspace.actor, account_events: session.actor_events)
          @controller = controller_class.new(workspace: @workspace, context: context, session: session)
        end
        super
      rescue Exception => error
        primary = error
        raise error, cause: error.cause
      ensure
        begin
          unless @controller
            begin
              context&.close(primary: primary)
            ensure
              session&.close
            end
          end
        ensure
          raise primary, cause: primary.cause if primary
        end
      end
    end

    private

    def build_form
      @tournaments = ListBox.new([], header: plan_header, quiet: true)
      @matches = ListBox.new([], header: match_header, quiet: true)
      @windows = ListBox.new([], header: text(_("Execution window")), quiet: true)
      @status = readonly(status_header, status_text)
      @readiness_operations = ListBox.new([], header: text(_("Readiness operations")), quiet: true)
      details = button(_("View details")) { preview }
      refresh_button = button(_("Check status")) { start_fixed(:catalog) }
      resume = button(_("Resume saved tournament")) { resume_fixed }
      standings = button(_("View tournament standings")) { show_standings }
      knockout = button(_("Preview knockout round")) { choose_knockout_seeds }
      approve_knockout = button(_("Accept displayed knockout pairings")) do
        shown = @controller.view[:phase_preview]
        start_fixed(:knockout_accept, phase_preview: shown[:preview]) if shown && shown[:state] == :confirmed
      end
      check_knockout = button(_("Check accepted knockout pairings")) { start_fixed(:knockout_readback) }
      preview_execution = button(_("Preview knockout match plan")) { start_fixed(:knockout_execution_preview) }
      accept_execution = button(_("Accept displayed knockout match plan")) do
        shown = @controller.view[:phase_execution_preview]
        start_fixed(:knockout_execution_accept, phase_execution_preview: shown[:preview]) if shown && shown[:state] == :confirmed
      end
      check_execution = button(_("Check accepted knockout match plan")) { start_fixed(:knockout_execution_readback) }
      ready = button(_("Ready")) { declare_fixed('ready') }
      withdraw = button(_("Withdraw readiness")) { declare_fixed('withdrawn') }
      check = button(_("Check uncertain operation")) { reconcile_fixed }
      deadline = button(_("Choose technical deadline")) { choose_deadline }
      target = button(_("Prepare local target")) { start_fixed(:request_match, expires_at: @deadline && @deadline[:selectors] == selectors ? @deadline[:value] : nil) }
      coordination = button(_("Check original coordination")) { start_fixed(:reconcile_coordination) }
      consent = button(_("Consent to the selected local match")) do
        admission = @controller.view[:admission]
        binding = admission && admission.dig(:status, 'binding')
        start_fixed(:consent, binding_digest: CoordinationContract.digest(binding)) if binding && admission[:state] == :confirmed
      end
      enter = button(_("Confirm local match entry")) do
        admission = @controller.view[:admission]
        id = admission && admission.dig(:status, 'consent', 'id')
        start_fixed(:enter, consent_id: id) if id && admission[:state] == :confirmed
      end
      entry_status = button(_("Check local match entry")) { start_fixed(:admission_status) }
      start = button(_("Start the selected local match")) do
        admission = @controller.view[:admission]
        binding = admission && admission.dig(:status, 'binding')
        start_fixed(:start_local_game, binding_digest: CoordinationContract.digest(binding)) if binding && admission[:state] == :confirmed
      end
      game_status = button(_("Check original local game")) { start_fixed(:local_game_status) }
      finalize = button(_("Save finished local match result")) do
        result = @controller.view[:local_game]
        status = result && result[:status]
        start_fixed(:finalize_local_game, revision: status['revision']) if result && result[:state] == :confirmed && status && status['finished']
      end
      @local_actions = ListBox.new([], header: text(_("My legal local moves")), quiet: true)
      move = button(_("Submit selected local move")) { submit_local_move }
      move_status = button(_("Check original local move")) do
        intent = (@move_intents || {})[selectors]
        start_fixed(:local_move_status, operation_id: intent[:operation_id]) if intent
      end
      back = button(_("Back"))
      make_form([@tournaments, @matches, @windows, @status, details, refresh_button, resume, standings, knockout, approve_knockout, check_knockout,
        preview_execution, accept_execution, check_execution, ready, withdraw,
        @readiness_operations, check, deadline, target, coordination, consent, enter, entry_status, start, game_status,
        @local_actions, move, *additional_game_fields, move_status, finalize, back], cancel: back)
      @form.accept_button = details
      @form.readiness_tick = method(:drain_fixed)
      back.on(:press) { finish if @readiness_pending && !@busy && !@finished }
      @tournaments.on(:move) do
        interaction(restore: false) do
          @controller.select_plan(selected_id)
          present_fixed
          start_fixed(:inspect)
        end
      end
      end_move = ->(*) { interaction(restore: false) { update_windows; start_fixed(:inspect) } }
      @matches.on(:move, &end_move)
      @windows.on(:move) { interaction(restore: false) { start_fixed(:inspect) } }
      @form.game_room_general_help_tips = [boundary_text]
    end

    def selectors
      match = @controller.view[:matches][@matches.index]
      window = match && match['windows'][@windows.index]
      return unless match && window
      {intent_id: selected_id.dup.freeze, match_id: match['match_id'].dup.freeze,
        leg: match['leg'], window_id: window['id'].dup.freeze}.freeze
    end

    def resume_fixed
      row = @controller.view[:tournaments].find { |r| r['__id'] == selected_id }
      recommendation = row && row.dig('progress', 'recommendation')
      return unless recommendation
      selection = recommendation['selectors']
      @matches.index = @controller.view[:matches].index { |m| m['match_id'] == selection['match_id'] && m['leg'] == selection['leg'] } || 0
      update_windows
      match = @controller.view[:matches][@matches.index]
      @windows.index = match['windows'].index { |w| w['id'] == selection['window_id'] } || 0
      start_fixed(recommendation['action'].to_sym)
    end

    def show_standings
      progress = @controller.view[:tournaments].find { |r| r['__id'] == selected_id }&.fetch('progress', nil)
      return unless progress
      lines = [completion_text(progress),
        text(_("Completed: %{completed}; remaining: %{remaining}; total: %{total}")) % {
          completed: progress['completed'], remaining: progress['remaining'], total: progress['total']}]
      if progress['group_state']
        lines << text(_("Group stage: %{state}")) % {state: group_state_text(progress['group_state'])}
        lines << text(_("Qualified: %{players}")) % {players: progress['qualified'].join(', ')}
      end
      if progress['knockout_state']
        lines << knockout_state_text(progress['knockout_state'])
        lines << text(_("Qualified: %{players}")) % {players: progress['qualified'].join(', ')}
        lines << text(_("Tournament winner: %{player}")) % {player: progress['champion']} if progress['champion']
      end
      progress['standings'].each do |row|
        lines << standings_row_text(row)
      end
      progress['results'].each do |result|
        lines << saved_result_text(result)
      end
      lines << text(_("Tournament points: win 2, draw 1, loss 0. Game points are recorded separately."))
      Standings.new(program: @program, content: lines.join("\r\n"), context: @context, lease: @lease).run
    end

    def start_fixed(action, **options)
      return if @readiness_pending || !current?
      selection = selectors
      return unless action == :catalog || selection
      @readiness_work ||= GameRoomBackground::Work.new(runtime: @program.class.app_runtime)
      @readiness_pending = {action: action, selected_id: selected_id, selection: selection,
        field: @form.index, window: @windows.index,
        positions: @form.fields.grep(EditBox).map { |f| [f, f.index, f.check] }}.freeze
      input = options.merge(action: action)
      input[:selectors] = selection unless action == :catalog
      @status.set_text(status_text)
      started = @readiness_work.start { @controller.perform(**input) }
      raise 'Worker FT2 nie przyjął pojedynczej czynności' unless started
    rescue Exception
      @readiness_pending = nil
      raise
    end

    def choose_knockout_seeds
      progress = @controller.view[:tournaments].find { |row| row['__id'] == selected_id }&.fetch('progress', nil)
      if progress && progress['knockout_state'] == 'completed'
        start_fixed(:knockout_preview)
        return
      end
      if progress && (progress['group_state'] == 'ready_knockout' || %w[ready_next_round tie_requires_resolution awaiting_series].include?(progress['knockout_state']))
        start_fixed(:knockout_preview)
        return
      end
      unless progress && progress['group_state'] == 'awaiting_seeding'
        @status.set_text(text(_("Complete all group matches and resolve qualification ties before previewing the knockout round.")))
        return
      end
      seeds = KnockoutSeeds.new(program: @program, content: progress['qualified'].join("\r\n"),
        qualified: progress['qualified'], context: @context, lease: @lease).run
      start_fixed(:knockout_preview, seeds: seeds) if seeds && current?
    end

    def drain_fixed
      return if @busy || !@readiness_pending || !current?
      outcome = @readiness_work.take
      return unless outcome
      pending, @readiness_pending = @readiness_pending, nil
      interaction(restore: false) do
        value, error = outcome
        raise error, cause: error.cause if error
        return consume_realtime_surface(value, pending) if value.key?(:realtime_surface)
        return consume_game_surface(value, pending) if value.key?(:private_surface)
        @controller.adopt(value, selected_id: pending[:selected_id])
        if [:local_game_move, :local_move_status].include?(pending[:action])
          result = value[:local_game]
          @move_intents&.delete(pending[:selection]) if result && [:confirmed, :unknown, :blocked].include?(result[:state])
        end
        present_fixed
        if pending[:selection]
          @matches.index = @controller.view[:matches].index { |m| m['match_id'] == pending[:selection][:match_id] } || 0
          update_windows
          @windows.index = pending[:window]
        end
        @status.set_text(status_text)
        pending[:positions].each { |f, caret, check| f.index, f.check = caret, check }
        @form.index = pending[:field]
        start_fixed(:inspect) if pending[:action] == :catalog && value.key?(:catalog) && selectors
      end
    end

    def additional_game_fields
      @game_surface_button = button(_("View")) { start_fixed(game_surface_action) if game_surface_available? }
      [@game_surface_button]
    end

    def game_surface_available?
      row = @controller.view[:tournaments].find { |item| item['__id'] == selected_id }
      GameResult::RESULT_POLICIES.include?(row&.dig('record', 'evidence', 'source', 'result_policy'))
    end
    def game_surface_action
      row = @controller.view[:tournaments].find { |item| item['__id'] == selected_id }
      id = row && row['record']['evidence']['source']['game_id']
      id ||= row && row['record']['evidence']['plan']['game_id']
      id && @workspace.registry.build(id).tournament_execution_kind == :realtime ? :local_realtime_view : :local_game_surface
    end

    def consume_realtime_surface(value, pending)
      result = value[:realtime_surface]
      return unless result && selectors == pending[:selection]
      unless result[:state] == :confirmed
        @controller.adopt(value.reject { |key, _| key == :realtime_surface }.merge(local_game: result), selected_id: pending[:selected_id])
        present_fixed
        return
      end
      require_relative 'local_realtime_game_dialog'
      MatchEntryScreen::RealtimeGame.new(program: @program, controller: @controller, selectors: pending[:selection],
        result: result, context: @context, lease: @lease).run
      start_fixed(:local_game_status) if current? && selectors == pending[:selection]
    end

    def consume_game_surface(value, pending)
      result = value[:private_surface]
      return unless result && selectors == pending[:selection]
      unless result[:state] == :confirmed
        @controller.adopt(value.reject { |key, _| key == :private_surface }.merge(local_game: result), selected_id: pending[:selected_id])
        present_fixed
        return
      end
      return if (@move_intents || {})[pending[:selection]]
      projection = result[:effect]
      choice = MatchEntryScreen::GameChoice.new(program: @program, spec: projection[:spec], guard: method(:current?),
        context: @context, lease: @lease).run
      return unless choice && current? && selectors == pending[:selection]
      @move_intents ||= {}
      intent = {operation_id: SecureRandom.uuid, revision: projection[:revision], move_selection: choice}.freeze
      @move_intents[pending[:selection]] = intent
      start_fixed(:local_game_move, **intent)
    end

    def present_fixed
      view = @controller.view
      @tournaments.update_options(view[:tournaments].map { |r| text(r['title']) }, keys: view[:tournaments].map { |r| r['__id'] })
      @tournaments.index = view[:tournaments].index { |r| r['__id'] == view[:selected_id] } || 0
      if @game_surface_button
        @form.public_send(game_surface_available? ? :show : :hide, @form.fields.index(@game_surface_button))
      end
      @matches.update_options(view[:matches].map { |m| match_text(m) }, keys: view[:matches].map { |m| m['match_id'] })
      update_windows
      actions = view.dig(:local_game, :status, 'actions') || []
      @local_actions.update_options(actions.map { |action| local_move_text(action) }, keys: actions.map { |action| JSON.generate(action) })
      @readiness_operations.update_options(view[:records].map do |r|
        text(_("Operation %{id}: %{state}; declaration: %{declaration}")) % {id: r['operation']['operation_id'],
          state: operation_state_text(r['status']), declaration: readiness_value_text(r['operation']['request']['availability'])}
      end, keys: view[:records].map { |r| r['operation']['operation_id'] })
      @status.set_text(status_text)
    end

    def update_windows
      match = @controller.view[:matches][@matches.index]
      windows = match ? match['windows'] : []
      @windows.update_options(windows.map { |w| text("#{Time.at(w['opens']).getlocal} — #{Time.at(w['closes']).getlocal}") }, keys: windows.map { |w| w['id'] })
    end

    def declare_fixed(availability)
      current = @controller.view[:current]
      return unless current
      start_fixed(:declare, availability: availability, expected_revision: current['ready_revision'])
    end

    def reconcile_fixed
      record = @controller.view[:records][@readiness_operations.index]
      start_fixed(:reconcile_readiness, operation_id: record['operation']['operation_id']) if record
    end

    def match_text(match)
      LocalMatchLabels.match(selected_record, match)
    end

    def selected_record
      view = @controller.view
      view[:tournaments].find { |row| row['__id'] == view[:selected_id] }.fetch('record')
    end

    def match_number(match)
      LocalMatchLabels.number(selected_record, match)
    end

    def status_text
      lines = [text(_("Local test — this computer only")), text(_("Test actor: %{actor}")) % {actor: @workspace.actor}]
      view = @controller.view
      append_readiness_status(lines, view)
      append_entry_status(lines, view)
      append_phase_status(lines, view)
      append_phase_execution_status(lines, view)
      lines << boundary_text
      lines.join("\r\n")
    end

    def append_readiness_status(lines, view)
      progress = view[:tournaments].find { |r| r['__id'] == view[:selected_id] }&.fetch('progress', nil)
      if progress
        lines << completion_text(progress) if progress['complete']
        lines << text(_("Tournament progress: %{completed} of %{total} matches completed")) % {completed: progress['completed'], total: progress['total']}
        progress['matches'].each do |row|
          lines << text(_("Saved match %{match}, leg %{leg}: %{stage}")) % {match: match_number(row), leg: row['leg'], stage: progress_stage_text(row['stage'])}
          lines << text(_("The execution authorization changed. Saved history is retained; transfer to another coordinator is not available yet.")) if row['interruption_reason'] == 'authority_changed'
          lines << text(_("The preparation authorization expired. Saved history is retained.")) if row['interruption_reason'] == 'authorization_expired'
          if row['result']
            lines << summary_text(row['result'])
          end
          lines << text(_("This match window has expired. Saved history is available.")) if row['window_expired'] && row['stage'] != 'completed'
        end
      end
      if view[:current]
        lines << text(_("Own readiness: %{state}; revision: %{revision}")) % {
          state: readiness_value_text(view[:current]['state']), revision: view[:current]['ready_revision']}
      end
      if view[:operation]
        effect = view[:operation]
        lines << text(_("Operation result: %{state}; original UUID: %{id}")) % {state: operation_state_text(effect[:state]), id: effect[:operation_id] || text(_("unknown"))}
        lines << text(_("Operation reason: %{reason}")) % {reason: effect[:reason]}
        if [:intent_conflict, :stale_revision].include?(effect[:reason])
          lines << text(_("The readiness revision changed. Check status before a new declaration."))
        end
      end
      lines << damaged_text if @controller.reason == :sandbox_corrupt
      lines << text(_("The status could not be read completely. The last valid view is retained.")) if @controller.reason == :read_failed
      lines << empty_text if @controller.reason == :no_accepted_plan
      lines << text(_("No confirmed registration for this test participant. Viewing does not join a tournament.")) if @controller.reason == :no_membership
      lines << loading_text if @controller.reason == :not_read
      if view[:coordination]
        result = view[:coordination]
        lines << text(_("Coordination: %{state}; reason: %{reason}; original UUID: %{id}")) % {
          state: result[:state], reason: result[:reason], id: result[:operation_id] || text(_("unknown"))}
        lines << text(_("Choose a technical deadline before preparing a local target.")) if result[:reason] == :technical_deadline_required
        lines << text(_("The technical deadline must be in the future and inside the selected window.")) if result[:reason] == :invalid_technical_deadline
        lines << target_text(result[:target]) if result[:target]
      end
      if @deadline && @deadline[:selectors] == selectors
        lines << text(_("Technical deadline: %{time}; policy: %{policy}")) % {
          time: Time.at(@deadline[:value]).getlocal.to_s, policy: connection_policy}
      end
      lines << text(_("The accepted source changed. New readiness and target writes are blocked; the original operation can still be checked.")) if @controller.reason == :source_changed
    end

    def append_entry_status(lines, view)
      if view[:admission]
        admission = view[:admission]
        lines << text(_("Local entry result: %{state}; reason: %{reason}")) % {state: admission[:state], reason: admission[:reason] || 'confirmed'}
        if admission[:status]
          status = admission[:status]
          lines << text(_("Selected local target: %{native}; table: %{table}")) % {
            native: status['binding']['native_uuid'], table: status['binding']['table_id']}
          lines << text(_("Own consent: %{consent}; own entry: %{entry}; present participants: %{count}")) % {
            consent: status['consent'] ? status['consent']['id'] : '-',
            entry: status['entry'] ? status['entry']['status'] : '-', count: status['participants'].size}
          if status['entry']
            lines << text(_("Confirmed seat: %{seat}; team: %{team}")) % {seat: status['entry']['seat'] + 1, team: status['entry']['team']}
          end
          lines << text(_("The grant is no longer current. New consent and entry are blocked.")) unless status['current']
        end
        lines << text(_("Entry result is uncertain. Check local match entry before retrying.")) if admission[:state] == :uncertain
      end
      if view[:local_game]
        result = view[:local_game]
        lines << text(_("Local game result: %{state}; reason: %{reason}")) % {state: result[:state], reason: result[:reason] || 'confirmed'}
        if result.dig(:status, 'receipt')
          status = result[:status]
          lines << text(_("Confirmed local game: %{id}; phase: %{phase}; recorded moves: %{count}")) % {
            id: status['session_id'], phase: local_phase_text(status['phase']), count: status['event_count']}
          lines << text(_("Current player: %{player}; local viewer: %{viewer}")) % {
            player: status['current_player'] || '-', viewer: status['viewer']}
          if status['last_move']
            lines << text(_("Last confirmed own move: %{id}")) % {id: status['last_move']['id']}
          end
          if status['result']
            saved = status['result']
            lines << saved_result_text(saved)
          end
          (status['standings'] || []).each do |row|
            lines << standings_row_text(row)
          end
        end
        if result[:state] == :uncertain && result.dig(:receipt, 'kind') == 'start'
          lines << text(_("Start result is uncertain. Check original local game before retrying."))
        end
        if result[:state] == :uncertain && result.dig(:receipt, 'kind') == 'result'
          lines << text(_("Match result is uncertain. Check original local game before retrying."))
        end
        lines << text(_("The move was confirmed, but refreshing the view failed. Check original local game.")) if result[:refresh_error]
      end
      if (@move_intents || {})[selectors]
        lines << text(_("Move result is uncertain. Check original local move before submitting another move."))
      end
    end

    def append_phase_status(lines, view)
      if view[:phase_preview]
        result = view[:phase_preview]
        if result[:state] == :confirmed
          plan = result[:plan]
          if plan['qualification']
            lines << text(_("Additional games decide group qualification. Their points do not change the original group table."))
          end
          if plan['replay']
            lines << text(_("Additional knockout games, attempt %{number}. Only unresolved matches are repeated.")) % {number: plan['replay']['attempt']}
          end
            unless view.dig(:phase_approval, :state) == :confirmed
              lines << text(_("Knockout preview only. No plan was accepted, no invitations were sent and no game was started."))
            end
          lines << text(_("Byes: %{players}")) % {players: plan['byes'].join(', ')}
          plan['matches'].each_with_index do |match, index|
            lines << text(_("Match %{number}: %{players}")) % {number: index + 1, players: match['participants'].join(', ')}
          end
        else
          lines << text(case result[:reason]
            when :group_stage_incomplete then _("Complete all group matches and resolve qualification ties before previewing the knockout round.")
            when :knockout_round_incomplete then _("Complete every knockout match and resolve ties before preparing the next round.")
            when :tournament_completed then _("Tournament completed")
          when :invalid_qualification_seeding then _("Enter every qualified unit exactly once in the chosen seed order.")
          when :invalid_knockout_configuration then _("This number of qualifiers cannot finish a knockout using the selected number of players per match and one advancing winner.")
          else result[:reason].to_s
          end)
        end
      end
      if view[:phase_approval]
        result = view[:phase_approval]
        lines << text(case result[:state]
        when :confirmed then _("Knockout pairings accepted and saved. Preview and accept the match plan to enable local matches.")
        when :uncertain then _("Knockout pairing acceptance is uncertain. Check accepted knockout pairings before retrying.")
        when :unknown then _("No accepted knockout pairings were found for this group plan.")
        else
          case result[:reason]
          when :not_author then _("Only the tournament organizer may accept knockout pairings.")
          when :phase_changed, :phase_conflict then _("The knockout preview differs from the current or already accepted pairings. Refresh the preview.")
          else result[:reason].to_s
          end
        end)
      end
    end

    def append_phase_execution_status(lines, view)
      if view[:phase_execution_preview]
        effect = view[:phase_execution_preview]
        if effect[:state] == :confirmed
          shown = effect[:preview]
          lines << text(_("Knockout match plan preview. Check players, seats and playing windows before accepting."))
          shown['assignments'].each_with_index do |match, index|
            players = match['players'].sort_by { |person| person['seat'] }.map { |person|
              text(_("Seat %{seat}: %{player}; game role: %{role}")) % {
                seat: person['seat'] + 1, player: person['username'], role: person['game_role']} }
            lines << text(_("Match %{number}: %{players}")) % {number: index + 1, players: players.join(', ')}
          end
          shown['source']['candidate']['windows'].each do |window|
            lines << [window['date'], window['start'], window['end_date'], window['end']].join(' ')
          end
        else
          lines << text(_("Accept the knockout pairings before preparing the match plan."))
        end
      end
      if view[:phase_execution]
        lines << text(case view[:phase_execution][:state]
        when :confirmed then _("Knockout match plan accepted. Refresh the plan list and select the knockout round to enable automatic invitations.")
        when :uncertain then _("Knockout match plan acceptance is uncertain. Check the accepted match plan before retrying.")
        else _("No accepted knockout match plan was found.")
        end)
      end
    end

    def boundary_text
      [text(_("Ready is not consent or entry. Each test participant must consent and confirm entry separately.")),
        text(_("The creator can start one local game after all four entries. Check original local game reads its saved history.")),
        text(_("Local entry and Start do not open a network game."))].join("\r\n")
    end

    def controller_class; LocalFixedTeamEntry; end
    def plan_header; text(_("Accepted fixed-team plans")); end
    def match_header; text(_("My fixed-team matches")); end
    def status_header; text(_("Fixed-team execution status")); end
    def connection_policy; LocalFixedTeamConnection::POLICY; end
    def damaged_text; text(_("The accepted fixed-team storage is damaged or incompatible. The last valid view is retained; no data was replaced.")); end
    def empty_text; text(_("No accepted fixed-team plan.")); end
    def loading_text; text(_("Use Check status to read accepted fixed-team plans.")); end
    def summary_text(summary)
      return generic_outcome_text(summary) if summary.key?('winners')
      text(_("Winner: %{winner}; game points: %{scores}")) % {winner: summary['winner'],
        scores: summary['scores'].map { |team, score| "#{text(team)}: #{score}" }.join(', ')}
    end
    def saved_result_text(result)
      if result['summary'].key?('winners')
        return text(_("Saved match %{match}, leg %{leg}; result: %{result}")) % {
          match: match_number(result), leg: result['leg'], result: generic_outcome_text(result['summary'])}
      end
      text(_("Saved match %{match}, leg %{leg}; winner: %{winner}")) % {
        match: match_number(result), leg: result['leg'], winner: result['summary']['winner']}
    end
    def generic_outcome_text(summary)
      summary['draw'] ? text(_("Draw")) : text(_("Winner: %{players}"))%{players:summary['winners'].map { |winner| text(winner) }.join(', ')}
    end
    def standings_row_text(row)
      unless row['score_for']
        return group_row_prefix(row) + (text(_("Place %{place}. ")) % {place: row['place']}) +
          (text(_("Team %{team}: tournament points %{points}, played %{played}, wins %{wins}, draws %{draws}, losses %{losses}")) % {
            team: row['team'], points: row['points'], played: row['played'], wins: row['wins'], draws: row['draws'], losses: row['losses']}) +
          ' ' + text(_("No numeric small points recorded."))
      end
      content = group_row_prefix(row) + (text(_("Place %{place}. ")) % {place: row['place']}) + text(_("Team %{team}: tournament points %{points}, played %{played}, wins %{wins}, draws %{draws}, losses %{losses}, game points for %{for}, game points against %{against}")) % {
        team: row['team'], points: row['points'], played: row['played'], wins: row['wins'], draws: row['draws'], losses: row['losses'], for: row['score_for'], against: row['score_against']}
      content + small_score_order_text(row)
    end

    def small_score_order_text(row)
      row['score_order'] == 'lower' ? ' ' + text(_("Small points: lower is better.")) : ''
    end

    def completion_text(progress)
      if progress['group_state']
        text(progress['complete'] ? _("Group matches completed") : _("Group matches in progress"))
      elsif progress['knockout_state']
        knockout_state_text(progress['knockout_state'])
      else
        text(progress['complete'] ? _("Tournament completed") : _("Tournament in progress"))
      end
    end

    def knockout_state_text(state)
      text(case state
      when 'awaiting_results' then _("Knockout round in progress")
      when 'awaiting_series' then _("The win target has not been reached. Prepare the next game in this knockout series.")
      when 'tie_requires_resolution' then _("Knockout draw: prepare an additional game for the tied participants.")
      when 'ready_next_round' then _("Knockout round completed; next round ready")
      when 'completed' then _("Tournament completed")
      when 'qualification_tiebreak' then _("Additional games decide group qualification. Their points do not change the original group table.")
      else state
      end)
    end

    def group_row_prefix(row)
      return '' unless row['group']
      (text(_("Group %{number}")) % {number: row['group'].delete_prefix('group-')}) + '. '
    end

    def group_state_text(state)
      text(case state
      when 'awaiting_results' then _("Waiting for all group results")
      when 'tie_requires_resolution' then _("Qualification tie requires resolution")
      when 'awaiting_seeding' then _("Qualification complete; knockout seeding required")
      when 'ready_knockout' then _("Qualification complete; automatic cross-group pairings ready")
      when 'seeding_tie_requires_resolution' then _("Group placing tie requires resolution before cross-group pairing")
      else state
      end)
    end

    def progress_stage_text(stage)
      text(case stage
      when 'planned' then _("Not started")
      when 'preparing' then _("Preparing the match")
      when 'awaiting_entry' then _("Waiting for participant entry")
      when 'ready_to_start' then _("Ready to start")
      when 'playing' then _("Game in progress")
      when 'awaiting_result' then _("Finished game awaiting result registration")
      when 'interrupted' then _("Match interrupted")
      when 'completed' then _("Result saved")
      else stage
      end)
    end

    def local_phase_text(phase)
      label = @controller.view.dig(:local_game, :status, 'phase_label')
      return text(label) if label
      text(case phase
      when 'awaiting_deal', 'round_complete' then _("Waiting for the deal")
      when 'bidding' then _("Bidding")
      when 'playing' then _("Playing cards")
      when 'finished' then _("Finished")
      else phase
      end)
    end

    def local_move_text(action)
      status = @controller.view.dig(:local_game, :status)
      index = status && status['actions'].index(action)
      if index && status['action_labels']
        return text(status['action_labels'][index] || action['action'])
      end
      case action['action']
      when 'deal' then text(_("Deal cards"))
      when /\Abid_\d+\z/ then text(_("Bid %{value}")) % {value: action['bid']}
      when 'select' then text(_("Play card %{card}")) % {card: text(GameRoomGames::Spades.new.playing_card_label(action['card']))}
      else text(action['action'])
      end
    end

    def submit_local_move
      return if @readiness_pending || !current?
      selection = selectors
      return unless selection
      @move_intents ||= {}
      intent = @move_intents[selection]
      unless intent
        result = @controller.view[:local_game]
        status = result && result[:status]
        action = status && status['actions'] && status['actions'][@local_actions.index]
        return unless action && result[:state] == :confirmed
        intent = {operation_id: SecureRandom.uuid, revision: status['revision'], move_selection: action}.freeze
        @move_intents[selection] = intent
      end
      start_fixed(:local_game_move, **intent)
    end

    def preview
      selection = selectors
      return unless selection
      row = @controller.view[:tournaments].find { |r| r['__id'] == selected_id }
      match = @controller.view[:matches][@matches.index]
      content = [match_text(match), row['record']['evidence']['plan']['id'], selection[:window_id], status_text].join("\r\n")
      Details.new(program: @program, content: content, context: @context, lease: @lease).run
    end
  end
end
require_relative 'local_fixed_team_execution_details'

require_relative 'local_dispatch_screen'
GameRoomTournaments::LocalFixedTeamExecutionScreen.prepend(GameRoomTournaments::LocalDispatchScreen)
