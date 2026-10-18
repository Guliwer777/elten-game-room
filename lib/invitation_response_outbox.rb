require_relative "game_room_background"
require_relative "network_errors"
require_relative "invitation_identity"

# Decisions are idempotent receipts, not invitations or visible notices.
# Keep a failed delivery separately from the recipient's already-made choice.
# The sender consumes duplicates by the exact invitation identity.
class InvitationResponseOutbox
  LIMIT = 500
  TTL = 300
  DEFAULT_LOCK = Mutex.new

  def self.default
    DEFAULT_LOCK.synchronize { @default ||= new }
  end

  def self.tick_default
    @default&.tick
  end

  def initialize(worker: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, current_user: -> { Session.name })
    runtime = Programs.current_runtime if defined?(Programs) && Programs.respond_to?(:current_runtime)
    @worker = worker || GameRoomBackground::Work.new(runtime: runtime)
    @clock, @current_user, @jobs, @lock = clock, current_user, {}, Mutex.new
  end

  def submit(row, response, &sender)
    user = row["recipient"].to_s
    raise ArgumentError, "Invitation belongs to another user" unless @current_user.call.to_s.casecmp?(user)
    key = GameRoomInvitationIdentity.key(row)
    job = @lock.synchronize do
      prune
      return @jobs[key][:response] if @jobs.key?(key)
      raise GameRoomNetworkErrors::PendingMove, "Invitation response queue is full" if @jobs.size >= LIMIT
      snapshot = row.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze
      @jobs[key] = { key: key, row: snapshot, user: user.dup.freeze, response: response,
        send: sender, expires: @clock.call + TTL, state: :sending }
    end
    begin
      sender.call(job[:row], response)
      @lock.synchronize { job[:state] = :delivered }
    rescue StandardError => error
      @lock.synchronize { failed(job, error) }
      raise unless GameRoomNetworkErrors.transient?(error)
    end
    response
  end

  # Called by the existing extension tick. HTTP is always off the UI thread;
  # one operation at a time, no sleeps, no disk and no repeating invitation.
  def tick
    @lock.synchronize do
      if (result = @worker.take)
        _value, error = result
        if @active && @jobs[@active[:key]].equal?(@active)
          error ? failed(@active, error) : @active[:state] = :delivered
        end
        @active = nil
      end
      prune
      return if @worker.busy? || @worker.closed?
      job = @jobs.values.find { |item| item[:state] == :pending && item[:next_at] <= @clock.call }
      return unless job
      job[:state] = :sending
      @active = job
      @worker.start do
        job[:send].call(job[:row], job[:response]) if @current_user.call.to_s.casecmp?(job[:user]) && @clock.call < job[:expires]
      end
    end
  end

  private

  def prune
    user, now = @current_user.call.to_s, @clock.call
    @jobs.delete_if { |_key, job| !user.casecmp?(job[:user]) || now >= job[:expires] }
  end

  def failed(job, error)
    if GameRoomNetworkErrors.transient?(error)
      job[:state] = :pending
      job[:next_at] = @clock.call + GameRoomNetworkErrors.retry_delay(error, normal: 15, rate_limit: 60)
    else
      @jobs.delete(job[:key])
    end
    Log.warning("ELTEN Game Room invitation response delivery failed: #{error.class}") if defined?(Log)
  end
end
