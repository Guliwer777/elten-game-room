require_relative 'peer_engine'
require_relative 'hurry'

module GameRoomPong
  # All matches exchange reliable owned actions: humans control themselves,
  # the owner controls bots. Replaceable positions remain separate. A delayed
  # owner snapshot never overwrites a human's own paddle or ball.
  module PeerPlay
    include Hurry
    def frame
      return if @closed || !@replay || @replay.finished?
      return if @control_ready == false
      tick
      now = @clock.call
      if @channel.epoch && connection_state.epoch != @channel.epoch
        local_connection = local_match?
        connection_state.epoch, @epoch_since = @channel.epoch, now
        connection_state.peers.clear
        @connection_peers = {}
        connection_state.sequence = connection_state.event_sequence = 0
        rally_state.deferred_events = []
        # A point already agreed by both players is waiting for durable
        # confirmation, not an unfinished rally to replay after reconnection.
        if local_connection
          @engine_epoch = connection_state.epoch
        else
          reset_rally unless awaiting_point?
        end
      end
      receive_peer_packets(now)
      receive_peer_events
      check_peer_agreement(now) if host? && !session_paused?
      established = if host?
        @required.all? { |u| (p = connection_state.peers[u.downcase]) && p.body['r'] == @replay.state[:rally] }
      else
        @host_ready == true && rally_state.snapshot != nil
      end
      connection_peers = @connection_peers || {}
      times = host? ? @required.map { |u| connection_peers[u.downcase]&.ack_updated_at } :
        [connection_peers[@owner.downcase]&.received_at]
      expired = times.any? do |received|
        received ? now - received > Client::STREAM_TIMEOUT :
          now > handshake_deadline
      end
      if expired && now - connection_state.last_reconnect > 10
        connection_state.last_reconnect = now
        connection_state.connection_started_at = now
        @channel.reconnect(reason: 'PeerStatusTimeout')
      end
      healthy = local_match? || (@channel.connected? && transport_members_ready? && established && !expired)
      was_playable = !rally_state.paused && rally_state.snapshot && rally_state.snapshot['goal'] == nil
      raw = surface_input
      prepare_first_serve(now, healthy) unless session_paused?
      announce_ready(now) if healthy && !session_paused?
      waiting = now < rally_state.ready_at || (host? && peer_service_waiting?) ||
        (!host? && rally_state.engine.turn.zero? && (@host_serve_wait == true || now < @host_ready_at))
      set_paused(session_paused? || !healthy || waiting, waiting: session_paused? || healthy && waiting)
      rally_state.engine.automatic_for(@side, Preferences.read(@program)['auto_return']) if @side != nil
      raw = sample_pointer_input(raw, !session_paused?)
      input = playable_input(raw, active: was_playable && !rally_state.paused && rally_state.engine.goal == nil, moving: !session_paused?)
      input['move'] = session_paused? ? 0 : raw.fetch('move', 0)
      if host? || @side != nil
        inputs = Array.new(@players.length) { {} }
        inputs[@side] = input if @side != nil
        each_physics_frame(now) do |frame_at|
          inputs[@side] = pointer_input(input, frame_at) if @side != nil && !session_paused?
          if !rally_state.paused && !rally_state.engine.goal && frame_at >= rally_state.ready_at
            rally_state.engine.step(inputs, now_ms: (frame_at * 1000).to_i)
            if (event = rally_state.engine.take_transition)
              emit_peer_event(event)
              emit_peer_effects(event) if host? && event['action'] == 'hit'
            end
            emit_peer_walls if host?
          else
            # Positioning is local even while waiting for a relay/HTTP result.
            # This does not advance the ball or retain a paused hit/serve.
            rally_state.engine.position(inputs, now_ms: (frame_at * 1000).to_i)
          end
        end
      end
      @mouse.finish_frame
      hurry_tick(healthy) unless session_paused?
      rally_state.snapshot = rally_state.engine.snapshot if host? || (@side != nil && rally_state.snapshot)
      send_peer_state(now)
      commit_peer_goal(now) if host?
      present
    end

    private

    def reset_rally
      options = @replay.state[:options]
      seed = Digest::SHA256.hexdigest("#{@match}:#{connection_state.epoch}:#{@replay.state[:rally]}")[0, 12].to_i(16)
      bots = @players.each_index.select { |side| bot_seat?(@players[side]) }
      owner_side = @players.index { |p| p.to_s.casecmp?(@owner) }
      physics_server = owner_side || 0
      guests = @players.each_index.reject { |side| side == physics_server }
      previous = rally_state.snapshot
      feedback = rally_state.engine&.movement_feedback if rally_state.engine && @engine_rally == @replay.state[:rally] - 1 && @engine_epoch == connection_state.epoch
      # Keep the existing mixed-match physics profile (including human reach),
      # not the all-human network profile merely because routing is now shared.
      guest = bots.empty? ? (rally_state.rotation.doubles? ? guests : guests.first) : nil
      rally_state.engine = PeerEngine.new(side: @side, authority: host?, level: options['difficulty'],
        arcade: options['arcade'], automatic: local_automatic, rally: @replay.state[:rally],
        first_server: first_server, teams: @teams, guest: guest, bots: bots,
        paddles: previous && previous['p'], shields: previous && previous['shields'],
        movement_feedback: feedback, rng: Random.new(seed), on_feedback: method(:play_feedback))
      @engine_rally, @engine_epoch = @replay.state[:rally], connection_state.epoch
      @bots = host? ? bots.map { |side| Bot.new(side, level: options['difficulty'], rng: Random.new(seed + side + 1)) } : []
      @bots.each { |bot| bot.step(rally_state.engine) }
      rally_state.snapshot = host? ? rally_state.engine.snapshot : nil
      @observer_turn = 0
      reset_rally_feedback
      @host_ready = false
      @host_serve_wait = false
      @last_wall = 0
      @last_bot_sound = 0
      @peer_disagreements = {}
      connection_state.event_sequence ||= 0
      @hurry_until = point_state.point_reason = nil
    end

    # Invoked on the existing UI frame: while simulating a local event or
    # applying validated peer input, never on a network worker.
    def play_feedback(snapshot)
      @audio.feedback(snapshot, viewer: audio_side, paused: rally_state.paused)
    end

    def receive_peer_packets(now)
      @channel.take_packets.each do |user, packet|
        # Native room membership is not paddle ownership. A replaced person
        # can remain as a spectator, but cannot overwrite the bot's position.
        next if host? && !@required.any? { |player| player.to_s.casecmp?(user) }
        body = packet['d']
        next unless body['r'].is_a?(Integer) && (body['r'] - @replay.state[:rally]).abs <= 1 && body['local'] == 1
        next unless host? ? valid_peer_position?(body) : valid_state?(body) && valid_peer_turn?(body)
        connection = ((@connection_peers ||= {})[user] ||= GameRoomRealtime::PeerState.new)
        next unless connection.receive(packet, now: now, last_sent: connection_state.sequence)
        # The other client can receive the durable point first. Its fresh
        # traffic must not look like a failed relay during our snapshot read.
        next unless body['r'] == @replay.state[:rally]
        peer = (connection_state.peers[user] ||= GameRoomRealtime::PeerState.new)
        next unless peer.receive(packet, now: now, last_sent: connection_state.sequence)
        next if session_paused?
        if host?
          side = @players.index { |p| p.to_s.casecmp?(user) }
          rally_state.engine.remote_paddle(side, body['x'], edges: body['edges']) if side != nil && side != @side
        else
          @host_ready = body['ready'] == true
          @host_serve_wait = body['serve_wait'] == true
          if body['ready_in'] && body['ready_in'] > 0 && rally_state.engine.turn.zero?
            # Relative time, never the other computer's wall clock. A guest
            # may receive the durable score before the owner does; that must
            # not allow a serve before the owner's next rally is ready.
            if rally_state.rotation.doubles?
              @host_ready_at = [@host_ready_at, now + body['ready_in']].max
            else
              rally_state.ready_at = [rally_state.ready_at, now + body['ready_in']].max
              rally_state.serve_announce_at = [rally_state.serve_announce_at, now + body['ready_in'] - 0.7].max unless @initial_rally
            end
          end
          if @side == nil
            rally_state.snapshot = body['state']
            @observer_turn = body['turn']
          else
            @players.each_index do |side|
              next if side == @side
              rally_state.engine.remote_paddle(side, body['state']['p'][side], edges: body['state']['edges']&.[](side))
            end
            body['state']['fx'].each do |number, kind, side, x, y|
              next unless number > @last_bot_sound
              rally_state.engine.remote_bot_sound(kind, side, x, y)
            end
            @last_bot_sound = [@last_bot_sound, body['state']['fx'].last&.first.to_i].max
            rally_state.snapshot ||= rally_state.engine.snapshot
          end
        end
      end
    end

    def valid_peer_turn?(body)
      body['turn'].is_a?(Integer) && body['turn'].between?(0, 2**31 - 1) && [nil, 0, 1].include?(body['goal'])
    end

    def valid_peer_position?(body)
      valid_peer_turn?(body) && finite?(body['x'], 1, 29) &&
        (!body.key?('edges') || valid_input_count?(body['edges'])) &&
        (!body.key?('serve_wait') || [true, false].include?(body['serve_wait']))
    end

    def receive_peer_events
      queued = (rally_state.deferred_events || []) + @channel.take_events
      rally_state.deferred_events = []
      # Relay delivery is ordered per sender, not across four different
      # senders. Authenticate first, then apply the shared action order. An
      # early return/effect must wait for its serve/preceding return, not vanish.
      queued = queued.select { |sender, packet| valid_peer_event?(packet['d']) && peer_event_sender?(sender, packet['d']) }
      queued.sort_by! do |_sender, packet|
        data = packet['d']
        [data['r'], data['turn'], %w[serve hit shield_hit goal timeout].include?(data['action']) ? 0 : 1]
      end
      queued.each do |sender, packet|
        data = packet['d']
        next if data['r'] < @replay.state[:rally]
        # A remote spectator listens to the owner's complete snapshot (fx
        # included). It has no playable physics timeline and may have joined
        # halfway through a rally. Only presentation notices need this lane.
        next if @side == nil && !host? && !%w[point hurry].include?(data['action'])
        future_action = data['r'] == @replay.state[:rally] && peer_event_waiting?(data)
        if session_paused? || data['r'] == @replay.state[:rally] + 1 || future_action
          # The durable score may arrive after the next reliable serve. Keep
          # it, but authenticate the actor before allowing it into this buffer.
          # Never silently truncate current actions behind deferred ones.
          if rally_state.deferred_events.length >= GameRoomRealtime::EventChannel::LIMIT
            rally_state.deferred_events.clear
            @channel.reconnect(reason: 'PeerActionBufferFull')
            break
          end
          rally_state.deferred_events << [sender, packet]
          next
        end
        next unless data['r'] == @replay.state[:rally]
        side = data['side']
        # Never repeat a locally performed action (also guards duplicate native
        # delivery). Direct peer events no longer need the owner's echo.
        next if !host? && side == @side && %w[serve hit shield_hit goal].include?(data['action'])
        applied = case data['action']
        when 'point'
          agrees = @side == nil ? rally_state.snapshot && rally_state.snapshot['goal'] == side && @observer_turn == data['turn'] :
            rally_state.engine.goal == side && rally_state.engine.turn == data['turn']
          preview_goal(side) if !host? && agrees
          next
        when 'hurry_request'
          accept_hurry(data) if host?
          next
        when 'hurry' then !host? && announce_hurry(data)
        when 'timeout'
          if !host? && side == rally_state.engine.server && rally_state.engine.serve_timeout(confirmed: true)
            point_state.point_reason = 'timeout'
            true
          end
        when 'serve', 'hit', 'shield_hit' then rally_state.engine.apply_return(data)
        when 'goal' then rally_state.engine.apply_miss(data)
        when 'effects' then !host? && rally_state.engine.apply_effects(data)
        when 'wall'
          if !host? && data['turn'] == rally_state.engine.turn
            rally_state.engine.wall_sound(data['x'], data['y'])
            true
          end
        end
        emit_peer_effects(data) if applied && host? && data['action'] == 'hit'
        note_play_activity if applied && %w[serve hit shield_hit].include?(data['action'])
      end
    end

    def peer_event_sender?(sender, data)
      if %w[serve hit shield_hit goal hurry_request].include?(data['action'])
        player = @players[data['side']]
        if bot_seat?(player)
          data['action'] != 'hurry_request' && !host? && @owner.casecmp?(sender)
        else
          player.to_s.casecmp?(sender) && data['side'] != @side
        end
      else
        !host? && @owner.casecmp?(sender)
      end
    end

    def peer_event_waiting?(data)
      case data['action']
      when 'serve', 'hit', 'shield_hit', 'goal'
        data['turn'] > rally_state.engine.turn + 1
      when 'effects', 'wall'
        data['turn'] > rally_state.engine.turn
      when 'point'
        data['turn'] > (@side == nil && !host? ? @observer_turn.to_i : rally_state.engine.turn)
      else
        false
      end
    end

    def valid_peer_event?(data)
      return false unless data.is_a?(Hash) && data['turn'].is_a?(Integer) && data['turn'].between?(0, 2**31 - 1)
      return false unless data['r'].is_a?(Integer) && data['r'] >= 0
      action = data['action']
      if %w[hurry_request hurry timeout].include?(action)
        return @players.each_index.include?(data['side']) && data['turn'] == (action == 'timeout' ? 1 : 0)
      end
      return false if data['turn'].zero?
      return [0, 1].include?(data['side']) if action == 'point'
      if action == 'wall'
        return data['side'] == nil && finite?(data['x'], 0, 30) && finite?(data['y'], -1000, 1020)
      end
      return false unless @players.each_index.include?(data['side'])
      if action == 'effects'
        return [true, false].include?(data['renew']) && [true, false].include?(data['invisible'])
      end
      return false unless %w[serve hit shield_hit goal].include?(action)
      if rally_state.rotation.doubles?
        rotation = Rotation.new(teams: @teams, rally: data['r'], first_server: first_server)
        return false unless data['side'] == rotation.hitter(data['turn'] - 1)
      end
      b = data['ball']
      return false unless valid_ball?(b)
      direction = action == 'goal' ? 0 : (rally_state.rotation.team(data['side']).zero? ? 1 : -1)
      b['dy'] == direction && (action == 'goal' || b['speed'] > 0)
    end

    def emit_peer_event(data)
      note_play_activity if %w[serve hit shield_hit].include?(data['action'])
      # A local human/bot match does not wait for a network endpoint. Observers
      # can later catch up from snapshots; no other player depends on this lane.
      return if local_match? && (!connection_state.epoch || !@channel.connected?)
      connection_state.event_sequence += 1
      packet = GameRoomRealtime::Protocol.encode(match: @match, epoch: connection_state.epoch, sequence: connection_state.event_sequence,
        kind: 'event', body: data.merge('r' => @replay.state[:rally]))
      @channel.reconnect(reason: 'PeerActionNotQueued') unless @channel.send_event(packet)
    end

    def emit_peer_effects(data)
      effects = rally_state.engine.host_effects(data['side'])
      emit_peer_event(effects) if effects
    end

    def emit_peer_walls
      rally_state.engine.events.each do |number, kind, _side, x, y|
        next unless number > @last_wall && kind == 'wall'
        emit_peer_event('action' => 'wall', 'side' => nil, 'turn' => rally_state.engine.turn, 'x' => x, 'y' => y)
      end
      @last_wall = rally_state.engine.events.last&.first || @last_wall
    end

    def send_peer_state(now)
      return unless connection_state.epoch
      goal = rally_state.snapshot && rally_state.snapshot['goal']
      goal_state = [connection_state.epoch, @replay.state[:rally], rally_state.engine.turn, goal] if goal != nil
      # A newly known result should not wait for the periodic paddle update.
      # This is still only status: commit_peer_goal requires every player's
      # matching result. Ordinary resends remain, including after UDP loss.
      return unless now >= connection_state.next_send || (goal_state && goal_state != @sent_goal_state)
      @sent_goal_state = goal_state
      connection_state.next_send = now + Client::SEND_INTERVAL
      connection_state.sequence += 1
      body = {'r' => @replay.state[:rally], 'local' => 1,
        'turn' => @side == nil && !host? ? @observer_turn.to_i : rally_state.engine.turn,
        'goal' => rally_state.snapshot && rally_state.snapshot['goal']}
      if host?
        ready = transport_members_ready? && @required.all? { |u| (p = connection_state.peers[u.downcase]) && p.body['r'] == @replay.state[:rally] }
        body.merge!('paused' => rally_state.paused, 'ready' => ready, 'state' => rally_state.snapshot)
        body['serve_wait'] = peer_service_waiting? if rally_state.rotation.doubles?
        body['ready_in'] = [[rally_state.ready_at - now, 0.0].max, 10.0].min if rally_state.ready_at.finite?
      else
        body['serve_wait'] = now < rally_state.ready_at if rally_state.rotation.doubles?
        body['x'] = @side == nil ? 15.0 : rally_state.engine.paddles[@side]
        body['edges'] = @side == nil ? 0 : rally_state.engine.edge_attempts[@side]
      end
      owner_connection = (@connection_peers || {})[@owner.downcase]
      ack = !host? && owner_connection ? owner_connection.sequence : 0
      @channel.send(GameRoomRealtime::Protocol.encode(match: @match, epoch: connection_state.epoch, sequence: connection_state.sequence,
        kind: host? ? 'state' : 'input', body: body, ack: ack))
    end

    def commit_peer_goal(now)
      return if point_state.pending_point
      return unless rally_state.engine.goal != nil && rally_state.engine.turn > 0 && !rally_state.paused
      return unless @required.all? do |user|
        peer = connection_state.peers[user.downcase]
        peer && peer.fresh?(now, timeout: Client::STREAM_TIMEOUT) && peer.body['r'] == @replay.state[:rally] &&
          peer.body['turn'] == rally_state.engine.turn && peer.body['goal'] == rally_state.engine.goal
      end
      point_state.pending_point = "#{@replay.state[:rally]}:#{rally_state.engine.goal}"
      point_state.pending_point += ':timeout' if point_state.point_reason == 'timeout'
      # This is presentation only. GameScreen still submits exactly this point
      # through action_for/repository and waits for authoritative replay.
      preview_goal(rally_state.engine.goal)
      emit_peer_event('action' => 'point', 'side' => rally_state.engine.goal, 'turn' => rally_state.engine.turn)
    end

    def transport_members_ready?
      !@channel.respond_to?(:required_members_present?) || @channel.required_members_present?
    end

    def local_match?
      host? && @required.empty?
    end

    def check_peer_agreement(now)
      return if awaiting_point?
      @peer_disagreements ||= {}
      @required.each do |user|
        peer = connection_state.peers[user.downcase]
        body = peer&.body
        if !body || !peer.fresh?(now, timeout: Client::STREAM_TIMEOUT) || body['r'] != @replay.state[:rally] ||
            (body['turn'] == rally_state.engine.turn && body['goal'] == rally_state.engine.goal)
          @peer_disagreements.delete(user)
          next
        end
        previous = @peer_disagreements[user]
        state = [body['turn'], body['goal']]
        if !previous || previous[0] != state
          @peer_disagreements[user] = [state, now]
        elsif now - previous[1] > Client::STREAM_TIMEOUT && now - connection_state.last_reconnect > 10
          # Fresh positions cannot repair a missing reliable game action. Only
          # the owner replaces the epoch, so every player restarts the same
          # unconfirmed rally; already agreed/durable points are preserved.
          if defined?(Log) && Log.respond_to?(:debug)
            Log.debug("Game Room Pong action_disagreement rally=#{@replay.state[:rally]} local_turn=#{rally_state.engine.turn} peer_turn=#{body['turn']} local_goal=#{rally_state.engine.goal.inspect} peer_goal=#{body['goal'].inspect}")
          end
          connection_state.last_reconnect = connection_state.connection_started_at = now
          @channel.reconnect(reason: 'PeerActionDisagreement')
          break
        end
      end
    end
  end
end
