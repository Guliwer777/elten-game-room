require_relative 'proposal_notice'
require_relative '../game_room_background'

module GameRoomTournaments
  # Drained by the existing extension tick. Reads happen only after a receipt;
  # no polling, automatic consent, table creation or retrying a failed read.
  class ProposalNoticeInbox
    LIMIT = 64
    attr_reader :last_error
    def initialize(service:, worker:, metadata:ProposalNotice.method(:metadata))
      @service, @worker = service, worker
      @metadata=metadata
      @pending, @seen, @verified = [], {}, {}
      @closed = false
    end

    def receive(id:, metadata:, sender:)
      return false if @closed || !id.is_a?(Integer) || id <= 0
      notice = @metadata.call(metadata)
      sender = Publication::Data.account(sender).downcase
      key = JSON.generate([notice, sender])
      return false if @seen.key?(key)
      return false if @pending.size >= LIMIT
      @seen[key] = true
      @seen.shift while @seen.size > LIMIT * 4
      @pending << [id, notice, sender]
      true
    rescue Publication::Invalid
      false
    end

    def tick
      return [] if @closed
      notices = []
      if (result = @worker.take)
        proof, error = result
        id, _metadata, sender = @running
        @running = nil
        if error
          @last_error = error
        else
          @verified[id] = [proof, sender]
          @verified.shift while @verified.size > LIMIT
          notices << [id, proof]
        end
      end
      unless @worker.busy? || @pending.empty?
        row = @pending.first
        started = @worker.start { @service.inspect(metadata: row[1], sender: row[2]) }
        if started
          @running = row
          @pending.shift
        end
      end
      notices
    end

    def verified(id); @verified[id]; end
    def close
      @closed = true
      @pending.clear
      @verified.clear
      @seen.clear
      @worker.close
    end
  end
end
