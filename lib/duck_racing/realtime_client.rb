# frozen_string_literal: true

require_relative 'realtime_projection'
require_relative '../axel_pong/client'
require_relative '../audio_ball/client'

module GameRoomDuckRacing
  class RealtimeClient
    attr_reader :projection, :native_client

    def initialize(program, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      transport: nil, client_factory: nil)
      @program, @clock, @transport = program, clock, transport
      @client_factory = client_factory || lambda do |kind, game, **options|
        type = kind == 'axel_pong' ? GameRoomPong::Client : GameRoomAudioBall::Client
        type.new(@program, game, **options)
      end
      @closed, @finishing, @retired_id = false, false, 0
      @control = {}
    end

    def bind_screen(session_id:, table_id:, owner:, viewer:, members:)
      raise ArgumentError, 'Realtime race client is already bound' if @binding
      @binding = {session_id: session_id, table_id: table_id, owner: owner.to_s.dup,
        viewer: viewer.to_s.dup, members: members}
    end

    def start
      !@closed && !@binding.nil?
    end

    def active?
      !@closed && !@finishing && !@native_client.nil?
    end

    def finishing?
      @finishing
    end

    def host?
      (@control['__table_owner'] || @binding&.[](:owner)).to_s.casecmp?(@binding&.[](:viewer).to_s)
    end

    def before_wait(parent_replay, viewer)
      return false if @closed
      raise ArgumentError, 'Realtime race client is not bound' unless @binding
      raise ArgumentError, 'Realtime race viewer changed' unless @binding[:viewer].casecmp?(viewer.to_s)
      tick if @finishing
      return false if @finishing
      owner = @control['__table_owner'] || @binding[:owner]
      incoming = @projection&.matches?(parent_replay) ? @projection : RealtimeProjection.from(parent_replay, owner: owner)
      unless incoming
        retire unless @finishing
        return false
      end
      return false if incoming.id <= @retired_id

      if @projection && incoming.identity != @projection.identity
        old_id = @projection.id
        retire
        # Replacing a selected player cancels the challenge. It must never
        # restart under the old identity while the race records cancellation.
        return false if incoming.id <= old_id
      end
      unless @native_client
        @projection = incoming
        @native_client = @client_factory.call(incoming.kind, incoming.game,
          clock: @clock, transport: @transport)
        arguments = @binding.merge(owner: owner, match_scope: incoming.match_scope, single_point: true)
        arguments[:first_server] = incoming.first_server if incoming.kind == 'axel_pong'
        @native_client.bind_screen(**arguments)
        @native_client.update_table_control(projected_control)
        @native_client.before_wait(@projection.replay, viewer)
        unless @native_client.start
          retire
          return false
        end
      else
        @projection.replay.state[:owner] = owner.to_s.dup
        @native_client.before_wait(@projection.replay, viewer)
      end
      true
    rescue StandardError
      retire
      raise
    end

    def update_table_control(session)
      return if @closed
      previous_epoch = control_epoch
      previous_owner = @control['__table_owner'] || @binding&.[](:owner)
      @control = session.slice('__table_owner', '__control_epoch', '__control_ready', '__frozen',
        '__players', '__initial_players', '__controllers').transform_values do |value|
        case value
        when Array then value.map { |item| item.is_a?(String) ? item.dup : item }
        when Hash then value.transform_values { |item| item.is_a?(String) ? item.dup : item }
        when String then value.dup
        else value
        end
      end
      return if @finishing || !@native_client
      roster = @control['__players']
      if roster && @projection.participants.map { |seat| roster[seat] } != @projection.players
        return retire
      end
      @native_client.update_table_control(projected_control)
      if previous_epoch != control_epoch || previous_owner != (@control['__table_owner'] || @binding[:owner])
        @pending = nil
        @projection.replay.state[:owner] = (@control['__table_owner'] || @binding[:owner]).to_s.dup
        @native_client.before_wait(@projection.replay, @binding[:viewer])
      end
    end

    # JSON-ready local context, never a separate native pong_point or
    # audio_ball_point write. Only the current race host offers a result.
    def context_data
      return {'duck_realtime_point' => nil} unless active? && host? && @control['__control_ready'] != false
      key = @projection.kind == 'axel_pong' ? 'pong_point' : 'audio_ball_point'
      point = @native_client.context_data[key]
      if point.is_a?(String) && (match = /\A0:([01])(:timeout)?\z/.match(point))
        @pending ||= {
          'id' => @projection.id, 'kind' => @projection.kind,
          'participants' => @projection.participants.dup, 'epoch' => control_epoch,
          'point' => point.dup, 'winner' => @projection.participants.fetch(match[1].to_i)
        }
        @native_client.detach_view
      end
      {'duck_realtime_point' => copy_receipt(@pending)}
    end

    # Call only for the race's accepted durable event, on every client. A
    # spectator need not have a local pending point. Rejected writes must not
    # call this method; their agreed point stays available for reconciliation.
    def finish_point(receipt)
      return false unless active? && receipt.is_a?(Hash)
      return false unless receipt['id'] == @projection.id && receipt['kind'] == @projection.kind &&
        receipt['participants'] == @projection.participants && receipt['epoch'] == control_epoch
      point = receipt['point']
      match = /\A0:([01])(:timeout)?\z/.match(point) if point.is_a?(String)
      return false unless match && receipt['winner'] == @projection.participants.fetch(match[1].to_i)
      return false if @pending && @pending != receipt
      return false unless @native_client.finish_single_point(winner: match[1].to_i)
      @projection.replay.winner = @projection.players.fetch(match[1].to_i)
      @finishing, @pending = true, nil
      @retired_id = [@retired_id, @projection.id].max
      true
    end

    def presentation_pending?
      @finishing && @native_client && @native_client.presentation_pending? || false
    end

    def attach_view(form, surface)
      @native_client.attach_view(form, surface) if active? && !@pending
    end

    def detach_view
      @native_client&.detach_view
    end

    def tick
      return if @closed || !@native_client
      @native_client.tick
      retire if @finishing && !@native_client.presentation_pending?
    end

    def frame
      return tick if @finishing
      @native_client&.frame unless @closed
    end

    def progress_frame(background: true)
      return tick if @finishing
      @native_client&.progress_frame(background: background) unless @closed
    end

    def network_task_ui(**options)
      @native_client&.network_task_ui(**options)
    end

    def show_settings
      @native_client&.show_settings if active?
    end

    def refresh_due?; false; end
    def background_progress?; true; end
    def action(_selection, _replay, _viewer); false; end
    def error(_status); end
    def automatic_error(_status); end

    def close
      return if @closed
      @closed = true
      retire
    end

    private

    def control_epoch
      (@control['__control_epoch'] || 'initial').to_s
    end

    def projected_control
      result = @control.dup
      result['__table_owner'] ||= @binding[:owner]
      result['__players'] = @projection.players.dup
      initial = @control['__initial_players'] || @control['__players']
      result['__initial_players'] = initial ? @projection.participants.map { |seat| initial[seat] } : @projection.players.dup
      result['__controllers'] = (@control['__controllers'] || {}).select { |name, _| @projection.players.include?(name) }
      result
    end

    def copy_receipt(receipt)
      return unless receipt
      receipt.transform_values { |value| value.is_a?(Array) || value.is_a?(String) ? value.dup : value }
    end

    def retire
      @retired_id = [@retired_id, @projection.id].max if @projection
      @native_client&.close
      @native_client = @projection = @pending = nil
      @finishing = false
    end
  end
end
