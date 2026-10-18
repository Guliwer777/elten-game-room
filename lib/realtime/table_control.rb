require 'digest'
require_relative '../game_participants'
require_relative '../game_room_ping'

module GameRoomRealtime
  # Native control epochs isolate packets from the previous controller. The
  # existing reconnect path repeats an unfinished rally, never its score.
  # Reliable player actions still travel directly between peers.
  module TableControl
    def bot_seat?(player)
      GameRoomParticipants.bot?(player) || (@seat_controllers || {})[player.to_s] == 'bot'
    end

    def update_table_control(session)
      return if @closed
      update_session_pause(session['__frozen'] == true)
      initial = session['__initial_players'] || session['__players']
      @initial_players = initial.dup if initial
      owner = session['__table_owner'] || @owner
      epoch = session['__control_epoch'] || 'initial'
      @control_ready = session['__control_ready'] != false
      return if !@control_ready || (@control_epoch == epoch && @owner == owner)
      controllers = session.fetch('__controllers', {})
      first = @control_epoch == nil && epoch == 'initial' && @owner == owner
      @control_epoch, @seat_controllers = epoch, controllers.dup
      return if first
      previous_channel = @channel
      previous_channel&.close
      @owner = owner.to_s
      reset_table_control
      @match = Digest::SHA256.hexdigest("#{@base_match}:#{epoch}")[0, 24]
      @channel = @channel_factory.call(program: @program, match: @match, owner: @owner,
        viewer: @viewer, clock: @clock, members: @members_provider)
      if @ping_service && @ping_service.communications_channel.equal?(previous_channel)
        @ping_service.communications_channel = @channel
      end
    end

    private

    def session_paused?
      @session_paused == true
    end

    # A durable session pause is independent of relay health/control epochs.
    # Keep networking alive; each client suspends only its playable timeline.
    def update_session_pause(paused)
      return if paused == session_paused?
      now = @clock.call
      elapsed = @session_pause_started ? [now - @session_pause_started, 0.0].max : 0.0
      @session_paused = paused
      @session_pause_started = paused ? now : nil
      session_pause_changed(paused, elapsed)
    end

    def note_play_activity
      @activity_transport&.note_realtime_activity(@activity_table, @activity_session)
    end

    def register_ping_channel
      @ping_service = GameRoomPing.for(@program)
      @ping_service.communications_channel = @channel
    end

    def unregister_ping_channel
      if @ping_service && @ping_service.communications_channel.equal?(@channel)
        @ping_service.communications_channel = nil
      end
    end
  end
end
