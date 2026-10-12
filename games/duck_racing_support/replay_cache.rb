# frozen_string_literal: true

require "digest"
require "thread"

module GameRoomDuckRacing
  # One authenticated prefix, not a cache indexed by every historical view.
  # Inputs are owned copies, including the repository's current interpretation
  # of each author and ID. A change anywhere in that prefix forces full replay.
  # Only serialized checkpoints survive the call: no caller, presenter or bot
  # can mutate the canonical model through a returned Replay.
  class ReplayCache
    MAX_BYTES = 8 * 1024 * 1024
    Entry = Data.define(:key, :identities, :count, :signature, :checkpoint)

    class Input
      attr_reader :session, :players, :events

      def initialize(session, events, repository)
        @session, @players, copied = Marshal.load(Marshal.dump(
          [session, repository.players_for(session), events.to_a]))
        @by_event = {}.compare_by_identity
        @records = copied.each_with_index.map do |event, index|
          # Distinguish positions even if the caller reuses the very same Hash.
          row = event.dup
          actor = repository.actor_of(row, @session)
          actor = actor.dup.freeze if actor.is_a?(String)
          record = [row, repository.event_id(row), actor]
          @by_event[row] = [index, record]
          record
        end
        @events = @records.map(&:first)
      end

      def actor_of(event, _session = nil); @by_event.fetch(event).last[2]; end
      def event_id(event); @by_event.fetch(event).last[1]; end
      def index_of(event); @by_event.fetch(event).first; end

      def signature(count = @records.length)
        Digest::SHA256.digest(Marshal.dump(@records.first(count))).freeze
      end
    end

    def initialize
      @lock = Mutex.new
      @generation = 0
      @entry = nil
    end

    # The block extends a private, deserialized checkpoint or constructs one
    # from scratch. It must return the reducer state BEFORE applying pending
    # participant transitions after the last decoded record. Those transitions
    # belong to the requested view, not necessarily to a future appended prefix.
    def reduce(input, context:, identities: [])
      key = Digest::SHA256.digest(Marshal.dump([input.session, input.players, context])).freeze
      entry, ticket = @lock.synchronize { [@entry, @generation += 1] }
      count = input.events.length
      prefix = 0
      checkpoint = nil
      same_context = entry && entry.key == key && entry.identities.length == identities.length &&
        entry.identities.zip(identities).all? { |left, right| left.equal?(right) }
      if same_context && entry.count <= count
        prefix_signature = input.signature(entry.count)
        if prefix_signature == entry.signature
          prefix = entry.count
          checkpoint = Marshal.load(entry.checkpoint)
          # No raw input changed or arrived. Pending participant transitions
          # are still applied afterwards to this independent, returned copy.
          return checkpoint if prefix == count
        end
      end
      result = yield(checkpoint, prefix)
      signature = input.signature
      encoded = Marshal.dump(result).freeze
      @lock.synchronize do
        if ticket == @generation
          # Reading an earlier view must not evict a longer current prefix.
          # If that old input was edited, the next full request still checks
          # the complete fingerprint instead of trusting the stale entry.
          historical = same_context && entry.equal?(@entry) && @entry.count > count
          unless historical
            @entry = encoded.bytesize <= MAX_BYTES ? Entry.new(key, identities.dup.freeze, count, signature, encoded) : nil
          end
        end
      end
      result
    end
  end
end
