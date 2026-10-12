# frozen_string_literal: true

require_relative '../../games/duck_racing_support/challenge_trace'
require_relative '../../games/duck_racing_support/challenge_presentation'
require_relative '../../games/duck_racing_support/session'
require_relative '../game_session_clock'
require_relative '../game_action_payload'
require_relative '../game_sounds'
require_relative '../game_surfaces/specifications'
require_relative '../realtime/progress'
require_relative '../realtime/task_ui'
require_relative 'challenge_audio'
require_relative 'realtime_client'
require_relative 'quiz_sounds'
require_relative 'answer_sounds'

module GameRoomDuckRacing
  # UI-owned attempts and presentation. Durable actions, commitments and
  # reveals still belong to the ordinary game executor; no worker reads keys
  # or writes this client's private model. Revisions of other people's ready/
  # alive actions must not restart a local clock, draft or sound sequence.
  class Client
    using GameRoomLocalization::Translations

    INPUT_LIMIT = 32
    attr_reader :session_id

    def initialize(program, game, transport: nil,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      session_time: ->(state) { (GameRoomSessionClock.for_state(state) * 1000).round },
      audio_factory: nil, realtime_factory: nil, progress_factory: nil, presentation_busy: nil)
      @program, @game, @clock, @session_time = program, game, clock, session_time
      @event_presentation_busy = presentation_busy || -> { false }
      @quiz_sounds = QuizSounds.new(program)
      @transport = transport
      @audio_factory = audio_factory || ->(**options) { ChallengeAudio.new(program, **options) }
      @realtime_factory = realtime_factory || -> { RealtimeClient.new(program, clock: clock, transport: transport) }
      @progress_factory = progress_factory || ->(**options, &block) { GameRoomRealtime::Progress.new(**options, &block) }
      @inputs, @control = [], {}
      @memory_presenters = []
      @closed, @refresh, @ready = false, false, false
      @memory_challenge, @memory_serial, @memory_sequence = 0, 0, 0
    end

    def bind_screen(session_id:, table_id:, owner:, viewer:, members:)
      raise ArgumentError, 'Duck Racing client is already bound' if @binding
      @session_id = session_id
      @binding = {session_id: session_id, table_id: table_id, owner: owner.to_s.dup,
        viewer: viewer.to_s.dup, members: members}
      @viewer = viewer.to_s.dup
      reset_realtime
    end

    def start
      return false if @closed || !@binding
      @progress ||= @progress_factory.call(program: @program, clock: @clock,
        key: [:duck_racing, @binding[:table_id], @session_id, @viewer]) do |background|
        frame(background: background)
      end
      true
    end

    def closed?; @closed; end
    def host?; same?(@control['__table_owner'] || @binding&.[](:owner), @viewer); end
    def background_progress?; true; end

    def update_table_control(session)
      return if @closed
      @control = copy(session.slice('__table_owner', '__control_epoch', '__control_ready', '__players',
        '__initial_players', '__controllers', '__seat_changes', '__id', 'id', 'player_one', '__insertion_user'))
      @realtime&.update_table_control(session)
      if @replay && @challenge && !roster_matches?(@replay)
        close_memory(@challenge[:id])
        clear_attempt
      end
    end

    def before_wait(replay, viewer)
      return false unless valid_replay?(replay, viewer)
      latest = @deferred_wait&.first || @replay
      return false if latest && replay.state[:revision] < latest.state[:revision]
      # The durable point is applied before the old challenge disappears.
      # Its goal recording may finish while the race prepares the next task.
      @realtime.finish_point(replay.state[:point_receipt]) if replay.state[:point_receipt]
      cancelled = replay.state[:last_resolution]
      if cancelled && cancelled[:cancelled]
        close_memory(cancelled[:id])
        reset_realtime if @realtime.projection&.id == cancelled[:id]
      end
      if @event_presentation_busy.call
        @deferred_wait = [replay, viewer]
        @ready = false
        return true
      end
      @deferred_wait = nil
      @replay, @seat = replay, replay.players.index { |name| same?(name, viewer) }
      @seat = nil if @seat && GameRoomParticipants.bot?(replay.players[@seat])
      incoming = roster_matches?(replay) ? identity_for(replay) : nil
      if incoming != @identity
        clear_attempt
        @identity = incoming
        @challenge = incoming && copy(replay.state.dig(:round, :challenge))
        prepare_resources if @challenge
        @refresh = true
      end
      unless @challenge && roster_matches?(replay) && !replay.finished?
        @realtime.before_wait(nil, @viewer)
        return true
      end

      acknowledge_requests
      if playing? && !@technical_error
        close_practice
        if realtime?
          ensure_realtime
        else
          @realtime.before_wait(nil, @viewer)
          ensure_attempt
        end
      else
        @realtime.before_wait(nil, @viewer)
      end
      update_view
      true
    end

    def after_events(replay, viewer, context:)
      before_wait(replay, viewer)
    end

    # The existing presenter supplies every accepted transition, including
    # several reveals in one refresh. Do not infer them from just the latest
    # memory snapshot: that would swallow the first of two quick digits.
    def event(_event, before, after, viewer, repository)
      return if @closed || !valid_replay?(after, viewer) || !before
      round = before.state[:round]
      round ||= after.state[:round]
      return unless round && %w[sound_memory sound_order].include?(round.dig(:challenge, :kind))
      id = round[:challenge][:id]
      return if id < @memory_challenge
      next_round = after.state[:round]
      event = if next_round&.dig(:challenge, :id) == id
        next_round.dig(:engine, :model, :public, :sound_event)
      else
        final_memory_event(before, after, round, repository)
      end
      return unless event && (id > @memory_challenge || event[:id] > @memory_serial)
      # A cold/rejoined client has not heard the earlier reveals. A heartbeat
      # or another unrelated transition must not replay the snapshot's last
      # choice as a new hint.
      previous = round.dig(:engine, :model, :public, :sound_event)
      return if previous && event[:id] <= previous[:id]

      @memory_challenge, @memory_serial = id, event[:id]
      return if round[:challenge][:kind] == 'sound_order' && event[:seat] != before.players.index { |name| same?(name, viewer) }
      @preview_audio&.play(nil) if round[:challenge][:kind] == 'sound_order'
      @memory_sequence += 1
      presentation = @memory_presenters.find { |entry| entry[:id] == id }
      unless presentation
        if @memory_presenters.length >= INPUT_LIMIT
          technical_failure(_('Too many challenge sounds are waiting to play. The challenge will be cancelled.')) if @challenge&.[](:id) == id
          return
        end
        presentation = {id: id, audio: build_audio(clock_ms: -> { milliseconds }, memory: true, challenge_id: id)}
        @memory_presenters << presentation
      end
      feedback = event[:sound] == :memory ? ChallengePresentation.memory_feedback(event, before.players) : {}
      if presentation[:audio].sound_event(event.merge(feedback).merge(id: @memory_sequence))
        presentation[:audio]
      end
    end

    def context_data
      return {} if @closed || !@binding
      output = {'duck_host' => host?, 'duck_seat' => @seat, 'duck_ready' => @ready && !@technical_error && roster_matches?(@replay),
        'duck_action' => copy(current_request)}
      if @transport
        # This is cached native metadata, not a request or a guessed create
        # limit. Refresh the scalar so a reconnected session's grant is used.
        output['duck_stack_entry_bytes'] = @transport.game_action_limits(@binding[:table_id])['max_stack_entry_bytes']
      end
      output.merge!(@realtime.context_data)
      output
    end

    # These projections contain neither a model nor resources. The UI game
    # may keep a WeakRef to this client; its session-worker copy must not.
    def local_view
      copy(@view)
    end

    def surface_spec(replay, viewer)
      return unless view_matches?(replay, viewer)
      if realtime? && !practicing?
        projection = @realtime.projection
        projection.surface_spec(viewer) if @realtime.active? && projection&.matches?(replay)
      elsif @view
        GameSurfaces::DuckChallengeSpec.new(challenge_id: @challenge[:id], kind: @challenge[:kind],
          viewer: @seat, view: local_view)
      end
    end

    def shortcuts(replay, viewer)
      return [] unless view_matches?(replay, viewer) && realtime? && @realtime.active?
      @realtime.projection.matches?(replay) ? @realtime.projection.shortcuts(viewer) : []
    end

    def attach_view(form, surface)
      if !@surface.equal?(surface) || !@form.equal?(form)
        @surface.before_input = nil if @surface.respond_to?(:before_input=)
        @surface&.deactivate_input if @surface.respond_to?(:deactivate_input)
        @form, @surface = form, surface
      end
      @surface.before_input = method(:prepare_local_input) if @surface.respond_to?(:before_input=)
      @progress&.attach(form)
      @realtime.attach_view(form, surface) if native_surface?(surface)
      present_local_view unless covered?
    end

    def detach_view
      @surface.before_input = nil if @surface.respond_to?(:before_input=)
      @surface&.deactivate_input if @surface.respond_to?(:deactivate_input)
      @realtime&.detach_view
      @progress&.detach
      @form = @surface = nil
    end

    def tick
      @progress ? @progress.update : frame
    end

    def progress_frame(background: true)
      @progress ? @progress.update(background: background) : frame(background: background)
      @realtime&.progress_frame(background: background)
    end

    def frame(background: false)
      return if @closed || @in_frame
      @in_frame = true
      begin
        @realtime&.tick # Finishing recordings progress even when !active?.
        advance_memory
        if @event_presentation_busy.call
          @ready = false
          neutralize_input
          return
        end
        before_wait(*@deferred_wait) if @deferred_wait
        @ready = participant? && !presentation_busy? && (!practicing? || practice_ready?) if @resources && !@technical_error
        if practicing? && !@technical_error && roster_matches?(@replay)
          @preview_audio&.step(milliseconds)
          consume_input unless background || covered?
          update_view if @view_dirty
        end
        if playing? && !@technical_error && roster_matches?(@replay)
          if realtime?
            ensure_realtime
          else
            ensure_attempt unless presentation_busy?
            if @trace
              if advance_preparation
                now = elapsed_ms
                changed = @trace.tick(at: now)
                @audio&.play(ChallengeEngine.stimulus(@trace.state, seat: @seat))
                @audio&.step(now)
                consume_input unless @technical_error || @preparation || background || covered?
              else
                # Keep observing physical edges while the field is disabled.
                # Deactivation here loses a new key in the first ready frame.
                @surface.clear_pending if @surface.respond_to?(:clear_pending)
              end
              queue_finished_trace
              update_view if changed || @view_dirty || @trace.finished?
              @quiz_sounds.tick(@view, seat: @seat, now_ms: elapsed_ms)
            elsif shared?
              if advance_preparation && !shared_preparation_pending?
                @preview_audio&.step(milliseconds)
                consume_input unless background || covered?
              else
                @surface.clear_pending if @surface.respond_to?(:clear_pending)
              end
              update_view if @view_dirty || @view&.[](:preparing)
            end
          end
        end
        neutralize_input if background || covered?
        queue_pulse
        unless background || covered?
          present_local_view
        end
      ensure
        @in_frame = false
      end
    end

    def refresh_due?
      changed, @refresh = @refresh, false
      changed
    end

    def network_task_ui(**options)
      GameRoomRealtime::TaskUI.new(**options, clock: @clock, tick: -> {
        progress_frame(background: true) unless GameRoomRealtime::TaskUI.updates_form?(options[:ui], @form)
      })
    end

    def action(selection, replay, viewer)
      return false unless selection['kind'] == 'duck' && selection['action'] == 'describe'
      return true unless valid_replay?(replay, viewer)
      seat = replay.players.index { |name| same?(name, viewer) }
      return true unless seat
      id = selection['card_id'] || selection['input']&.[]('card')
      card = replay.state.dig(:race, :racers, seat, :hand)&.find { |item| item.id == id }
      announce(@game.card_description(card.type)) if card
      true
    end

    def show_settings; @realtime.show_settings if playing? && realtime?; end
    def error(status); automatic_error(status); end

    def automatic_error(status)
      if status == :local_storage_unavailable || status == :invalid && @trace_request
        technical_failure(_('Your challenge attempt could not be saved. The challenge will be cancelled.'))
      end
    end

    def close
      return if @closed
      @closed = true
      clear_attempt
      detach_view
      @progress&.close
      @realtime&.close
      close_memory
      @replay = @game = nil
      @deferred_wait = nil
    end

    private

    def prepare_resources
      @resources = @game.resources_for(@replay.state[:options])
      if @resources[:fingerprint] != @replay.state[:fingerprint]
        technical_failure(_('The installed word or question sets do not match this table. The challenge will be cancelled.'))
      else
        @ready = participant? && !presentation_busy? && (!practicing? || practice_ready?)
      end
    rescue QuestionSets::Unavailable, IOError, SystemCallError => error
      technical_failure(_('The challenge resources could not be loaded. The challenge will be cancelled.'), error)
    end

    def ensure_attempt
      return if @trace || @watch_view || presentation_busy?
      if shared?
        if @challenge[:kind] == 'sound_order' && participant? && !@shared_preparation_started
          @shared_preparation_started = true
          # Do not replay a start cue when joining an already running attempt.
          if shared_preparation_pending?
            begin_preparation(delay_ms: [ChallengeEngine::ORDER_PREPARATION_DELAY_MS - sequential_ms, 0].max)
          end
        end
        return
      end
      engine = ChallengeEngine.start(@challenge, resources: @resources) if !participant? || committed?
      if engine
        @watch_view = ChallengeEngine.view(engine, seat: @seat)
        @watch_view[:own] = (@watch_view[:own] || {}).merge(done: true) if committed?
      else
        @origin_ms = milliseconds
        @trace = ChallengeTrace.new(@challenge, seat: @seat, resources: @resources)
        @trace.tick(at: 0)
        if ChallengeEngine::SPEED_TYPES.include?(@challenge[:kind]) && @challenge[:kind] != 'count_ducks'
          begin_preparation
        end
        @audio = build_audio(clock_ms: -> { elapsed_ms }) if AudioChallenges::TYPES.value?(@challenge[:kind])
        @audio&.play(ChallengeEngine.stimulus(@trace.state, seat: @seat))
        queue_finished_trace
      end
      @view_dirty = true
    end

    def ensure_realtime
      active = @realtime.active?
      return if active
      return if @realtime.finishing?
      started = @realtime.before_wait(@replay, @viewer)
      if started
        @refresh = true
        @realtime.attach_view(@form, @surface) if @form && native_surface?(@surface)
      else
        technical_failure(_('The audio game could not be started. The challenge will be cancelled.'))
      end
    end

    def practice_ready?
      !!(@practice_ready || @replay.state.dig(:round, :ready, @seat))
    end

    def close_practice
      return unless @view&.[](:practice)
      @preview_audio&.close
      @preview_audio = nil
      @view = nil
      neutralize_input
      @refresh = true
    end

    def preview_sound(**cue)
      @preview_audio ||= build_audio(clock_ms: -> { milliseconds }, memory: true)
      @preview_audio.preview(**cue)
    end

    def practice_input(input)
      return if practice_ready?
      if input[:kind].to_s == 'ready'
        @practice_ready = true
        @preview_audio&.close
        @preview_audio = nil
        @ready = !presentation_busy?
        @view_dirty = true
        neutralize_input
      elsif input[:kind].to_s == 'preview'
        code = input[:value]
        case @challenge[:kind]
        when 'simon'
          preview_sound(sound: :simon, tone: code - 0x30) if (0x31..0x35).include?(code)
        when 'hit_duck'
          preview_sound(sound: :target, pan: (code - 0x35) / 4.0) if (0x31..0x39).include?(code)
        when 'rhythm'
          preview_sound(sound: :rhythm, tone: code == 0x46 ? 'f' : 'j') if [0x46, 0x4A].include?(code)
        when 'audio_ball'
          lane = {0x26 => 'up', 0x57 => 'up', 0x25 => 'left', 0x44 => 'left', 0x28 => 'down', 0x53 => 'down'}[code]
          preview_sound(sound: :audio_ball, tone: lane) if lane
        end
      end
    end

    def build_audio(clock_ms:, memory: false, challenge_id: @challenge[:id])
      @audio_factory.call(clock_ms: clock_ms,
        on_announcement: ->(message) { announce(message) },
        on_action: ->(action, at) {
          if !memory && @trace && !@technical_error
            if @challenge[:kind] == 'count_ducks' && action[:kind] == :playback_finished &&
                @trace.state[:model].dig(:private, :players, @seat, :phase) == :listening
              # Keep the initial playback unacknowledged until the start cue.
              # The existing model then starts its response clock after the cue,
              # not at the end of the recording. F5 replays keep their clock.
              begin_preparation(acknowledgement: action)
            elsif @trace.submit(action, at: at)
              @view_dirty = true
            end
          end
        },
        on_error: ->(error) {
          # A final memory cue can outlive its result. Its failure must not
          # cancel an unrelated new challenge that is already being prepared.
          if @challenge&.[](:id) == challenge_id
            technical_failure(_('The challenge sounds could not be played. The challenge will be cancelled.'), error)
          elsif defined?(Log)
            Log.warning("Power Games Duck Racing completed challenge audio failed: #{error.class}: #{error.message}")
          end
        })
    end

    def begin_preparation(acknowledgement: nil, delay_ms: ChallengeEngine::PREPARATION_DELAY_MS)
      @preparation = {acknowledgement: acknowledgement, finished: false}
      @preparation_audio = @audio_factory.call(clock_ms: -> { milliseconds },
        on_action: ->(action, _at) {
          @preparation[:finished] = true if @preparation && action[:kind] == :playback_finished
        },
        on_error: ->(error) {
          technical_failure(_('The challenge sounds could not be played. The challenge will be cancelled.'), error)
        })
      @preparation_audio.play(id: 1, requested_ms: milliseconds + delay_ms,
        events: [{sound: :countdown, offset_ms: 0, duration_ms: ChallengeEngine::COUNTDOWN_MS}])
      @view_dirty = true
    end

    def advance_preparation
      return true unless @preparation
      @preparation_audio.step(milliseconds)
      return false if @technical_error || !@preparation[:finished]

      preparation, @preparation = @preparation, nil
      @preparation_audio.close
      @preparation_audio = nil
      if preparation[:acknowledgement]
        @trace.submit(preparation[:acknowledgement], at: elapsed_ms)
      elsif !shared?
        # Measure from the actual local cue, including after a delayed frame.
        # Different clients never subtract each other's clock readings.
        @origin_ms = milliseconds
      end
      @view_dirty = true
      # The next projection enables the field; there is no extra blank frame.
      false
    end

    def shared_preparation_pending?
      @challenge[:kind] == 'sound_order' && sequential_ms < ChallengeEngine::ORDER_PREPARATION_MS
    end

    def prepare_local_input
      return unless @preparation && !@closed && !@technical_error && !covered? &&
        roster_matches?(@replay) && surface_matches? && @surface.input_selected?(@form)

      # Native EditBox consumes characters before Form's timers run. Check
      # only the existing cue here, so a finished recording opens the field
      # before that batch is read. No extra timer, model tick or speech wait.
      advance_preparation
      update_view if @view_dirty
      present_local_view
    end

    def advance_memory
      presentation = @memory_presenters.first
      return unless presentation
      presentation[:audio].step(milliseconds)
      unless presentation[:audio].busy?
        presentation[:audio].close
        @memory_presenters.shift
      end
    end

    def close_memory(id = nil)
      @memory_presenters.reject! do |presentation|
        next false if id && presentation[:id] != id
        presentation[:audio].close
        true
      end
    end

    def consume_input
      return unless participant? && @surface.respond_to?(:take_input) && surface_matches?
      unless @surface.input_active?(@form)
        # A native Tab focuses the new field before its first update. Keep
        # that focus registration so the next physical edge is captured;
        # do not consume anything until the field has actually updated.
        neutralize_input unless @surface.respond_to?(:input_selected?) && @surface.input_selected?(@form)
        return
      end
      @surface.activate_input if @surface.respond_to?(:activate_input)
      @surface.take_input(@form).each do |input|
        if practicing?
          practice_input(input)
        elsif @trace
          next unless @trace.submit(input, at: elapsed_ms)
          @view_dirty = true
          GameRoomSounds.play(@program, AnswerSounds.local_cue(@trace))
          if input[:kind].to_s == 'tone' && %w[rhythm simon].include?(@challenge[:kind])
            @audio.feedback(sound: @challenge[:kind].to_sym, tone: input[:value])
          end
          @audio&.play(ChallengeEngine.stimulus(@trace.state, seat: @seat))
        elsif shared? && @inputs.length < INPUT_LIMIT
          candidate = copy(@replay.state[:round][:engine])
          now = sequential_ms
          @inputs.each { |request| ChallengeEngine.submit(candidate, seat: @seat, action: request['input'], now_ms: now, resources: @resources) }
          if @challenge[:kind] == 'sound_order' && input[:kind].to_s == 'preview'
            position = input[:value]
            if position.is_a?(Integer) && position.between?(1, 8) && !ChallengeEngine.finished?(candidate)
              tone = ChallengeEngine.view(candidate, seat: @seat).fetch(:own).fetch(:arrangement).fetch(position - 1)
              preview_sound(sound: :pitch, tone: tone)
            end
            next
          end
          if ChallengeEngine.submit(candidate, seat: @seat, action: input, now_ms: now, resources: @resources)
            @inputs << request('input').merge('input' => wire_input(input))
          end
        end
      end
    end

    def queue_finished_trace
      return if !@trace&.finished? || committed? || @technical_error
      @trace_request ||= request('submit_trace').merge('trace' => @trace.snapshot)
    end

    def acknowledge_requests
      round = @replay.state[:round]
      @trace_request = nil if committed?
      if shared? && (engine = round[:engine]) && participant?
        accepted = engine[:last_press].fetch(@seat)
        @inputs.reject! { |action| action['input']['press_id'] <= accepted }
        candidate = copy(engine)
        @inputs.select! do |action|
          ChallengeEngine.submit(candidate, seat: @seat, action: action['input'], now_ms: sequential_ms, resources: @resources)
        end
      end
      @pulse = nil if @pulse && round[:last_seen][@seat].to_i > @pulse_at
    end

    def queue_pulse
      return unless @challenge && participant? && !@technical_error
      return if playing? && realtime? || @trace_request || !@inputs.empty? || @pulse
      round = @replay.state[:round]
      return if round[:private]&.dig(:reveals, @seat)
      return if round[:attempts]&.key?(@seat)
      return if round[:private]&.fetch(:phase) == :revealing
      last = round[:last_seen].fetch(@seat)
      return if @session_time.call(@replay.state) < last + Session::PULSE_MS
      @pulse_at, @pulse = last, request('alive')
    end

    def current_request
      return if @event_presentation_busy.call
      return unless @challenge && participant? && roster_matches?(@replay)
      @cancel_request || @trace_request || @inputs.first || @pulse
    end

    def update_view
      return if @technical_error
      return unless practicing? || playing? && !realtime?
      view = if practicing?
        {type: @challenge[:kind], seats: @challenge[:participants], practice: true, own: {ready: !!practice_ready?}}
      elsif @trace
        ChallengeEngine.view(@trace.state, seat: @seat)
      elsif shared?
        ChallengeEngine.view(@replay.state[:round][:engine], seat: @seat)
      else
        copy(@watch_view)
      end
      return unless view
      view[:preparing] = true if @preparation || shared? && shared_preparation_pending?
      unless shared? || practicing?
        # Local expiry is not evidence that another client's attempt ended.
        view[:finished] = false
        view[:own] = (view[:own] || {}).merge(done: true) if @trace&.finished? || committed?
        [:completed, :ready].each do |key|
          next unless view[key]
          view[key] = @challenge[:participants].to_h do |seat|
            [seat, seat == @seat && @trace&.finished? || @replay.state.dig(:round, :private, :commitments)&.key?(seat) ||
              @replay.state.dig(:round, :attempts)&.key?(seat) || false]
          end
        end
      end
      view[:player_names] = @replay.players.each_with_index.to_h { |name, seat| [seat, name.dup] }
      if view != @view
        presentation = ChallengePresentation.project(kind: @challenge[:kind], view: view, viewer: @seat, previous_view: @view)
        initial_view = @view.nil?
        @view = view
        announced = announce(presentation[:announcement]) unless presentation[:announcement].empty?
        if initial_view && (announced || participant? && ChallengePresentation.autoplay?(@challenge[:kind]))
          @unfocused_prompt = true
        end
      end
      @view_dirty = false
    end

    def present_local_view
      return unless @view && surface_matches? && @surface.respond_to?(:present)
      return if @presented_surface.equal?(@surface) && @presented_view.equal?(@view)
      @surface.present(local_view)
      if @unfocused_prompt
        # A normal first wait would repeat the question in the field caption
        # and interrupt its queued announcement. Quiet waits clear this native
        # one-shot flag themselves. Do not suppress a later Tab from chat.
        field = @surface.fields.first if @surface.respond_to?(:fields)
        if field && @form&.fields&.[](@form.index.to_i).equal?(field)
          field.suppress_next_focus! if field.respond_to?(:suppress_next_focus!)
        end
        @unfocused_prompt = false
      end
      @presented_surface, @presented_view = @surface, @view
    end

    def technical_failure(message, error = nil)
      return if @technical_error || @closed
      @technical_error = true
      @ready = false
      @audio&.close
      @preview_audio&.close
      @preparation_audio&.close
      @trace_request = @pulse = nil
      @inputs.clear
      @cancel_request = request('cancel').merge('reason' => 'technical') if participant?
      @refresh = true
      announce(message)
      if error && defined?(Log)
        Log.warning("Power Games Duck Racing challenge failed: #{error.class}: #{error.message}")
      end
    end

    def final_memory_event(before, after, round, repository)
      return unless round[:engine] && after.state.dig(:last_resolution, :id) == round[:challenge][:id] &&
        !after.state[:last_resolution][:cancelled]
      candidate = copy(round[:engine])
      events = after.accepted_events.drop(before.accepted_events.length)
      result = nil
      GameRoomActionPayload.each(events, 'duck_racing', repository, @control) do |data, actor, _batch|
        next unless data['action'] == 'input' && data['challenge'] == round[:challenge][:id]
        seat = before.players.index { |name| same?(name, actor) }
        next unless ChallengeEngine.submit(candidate, seat: seat, action: data['input'],
          now_ms: data['at'] - round[:started_at], resources: @resources)
        result = candidate.dig(:model, :public, :sound_event)
      end
      result
    end

    def clear_attempt
      @quiz_sounds.reset
      @audio&.close
      @preview_audio&.close
      @preview_audio = nil
      @practice_ready = false
      @shared_preparation_started = false
      @preparation_audio&.close
      @preparation_audio = nil
      @audio = @trace = @watch_view = @view = @origin_ms = nil
      @preparation = nil
      @presented_surface = @presented_view = nil
      @unfocused_prompt = false
      @trace_request = @cancel_request = @pulse = @resources = nil
      @identity = @challenge = nil
      @inputs.clear
      @ready = @technical_error = @view_dirty = false
      neutralize_input
    end

    def reset_realtime
      @realtime&.close
      @realtime = @realtime_factory.call
      @realtime.bind_screen(**@binding)
      @realtime.update_table_control(@control)
      @realtime.start
    end

    def request(action); {'kind' => 'duck', 'action' => action, 'challenge' => @challenge[:id]}; end
    def copy(value); value.nil? ? nil : Marshal.load(Marshal.dump(value)); end
    def wire_input(value); value.to_h { |key, item| [key.to_s, item.is_a?(Symbol) ? item.to_s : item] }; end
    def same?(first, second); first.to_s.casecmp?(second.to_s); end
    def milliseconds; (@clock.call * 1000).floor; end
    def elapsed_ms; [milliseconds - @origin_ms, 0].max; end
    def sequential_ms; [@session_time.call(@replay.state) - @replay.state[:round][:started_at], 0].max; end
    def covered?; @progress ? @progress.covered? : !@form; end
    def presentation_busy?; @realtime&.finishing? || @memory_presenters.any? { |entry| entry[:audio].busy? }; end
    def playing?; @challenge && @replay.state.dig(:round, :phase) == :playing; end
    def realtime?; @challenge && ChallengeEngine::REALTIME.include?(@challenge[:kind]); end
    def shared?; @challenge && ChallengeEngine::SHARED.include?(@challenge[:kind]); end
    def practicing?
      @challenge && @replay.state.dig(:round, :phase) == :preparing && ChallengeEngine::PRACTICE_TYPES.include?(@challenge[:kind])
    end
    def participant?; @challenge && @challenge[:participants].include?(@seat); end
    def committed?
      @replay.state.dig(:round, :private, :commitments)&.key?(@seat) || @replay.state.dig(:round, :attempts)&.key?(@seat)
    end

    def identity_for(replay)
      challenge = replay.state.dig(:round, :challenge)
      return unless challenge && !replay.finished?
      [challenge[:id], challenge[:kind], challenge[:seed], challenge[:participants].dup,
        challenge[:participants].map { |seat| replay.players[seat].to_s.downcase }, @seat]
    end

    def valid_replay?(replay, viewer)
      !@closed && @binding && same?(viewer, @viewer) && replay&.state.is_a?(Hash) &&
        replay.state[:session_id] == @session_id && replay.state[:revision].is_a?(Integer)
    end

    def roster_matches?(replay)
      players = @control['__players']
      challenge = replay&.state&.dig(:round, :challenge)
      !players || !challenge || challenge[:participants].all? { |seat| same?(players[seat], replay.players[seat]) }
    end

    def view_matches?(replay, viewer)
      valid_replay?(replay, viewer) && @identity && @identity == identity_for(replay) && !@technical_error
    end

    def surface_matches?
      spec = @surface.spec if @surface.respond_to?(:spec)
      spec.is_a?(GameSurfaces::DuckChallengeSpec) && @challenge &&
        spec.challenge_id == @challenge[:id] && spec.kind == @challenge[:kind] && spec.viewer == @seat
    end

    def native_surface?(surface)
      return false unless realtime? && @realtime.active?
      @challenge[:kind] == 'axel_pong' ? surface.respond_to?(:on_pong_command=) : surface.respond_to?(:on_audio_ball_command=)
    end

    def neutralize_input
      @surface.deactivate_input if @surface.respond_to?(:deactivate_input)
    end

    def announce(text)
      return if text.to_s.empty? || !GameRoomBackgroundPolicy.speech?(@program, covered: covered?)
      speak(GameRoomContent.utf8(text.to_s), stop: false, break_sequence: false)
      true
    end
  end
end
