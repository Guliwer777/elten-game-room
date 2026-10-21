# frozen_string_literal: true

require 'digest'
require 'thread'

# One owned, authenticated prefix. A changed earlier record, actor, session or
# dependency invalidates it; returned reducers never share its mutable model.
class GameRoomReplayCache
  MAX_BYTES = 8 * 1024 * 1024
  Entry = Data.define(:key, :identities, :count, :signature, :checkpoint)

  class Input
    attr_reader :session, :players, :events, :retained_bytes

    def initialize(session, events, repository, previous: nil)
      @session, @players = Marshal.load(Marshal.dump([session, repository.players_for(session)]))
      @by_event = {}.compare_by_identity
      @sizes = []
      @retained_bytes = 0
      @signatures = [Digest::SHA256.digest('authenticated-replay-prefix-v1').freeze]
      @records = events.to_a.each_with_index.map do |event, index|
        prior = previous && previous.record_at(index)
        # Reuse only owned, sealed values. Recheck authentication even for an
        # unchanged raw event; its current controller interpretation may differ.
        row = prior && prior.first.eql?(event) ? prior.first : Marshal.load(Marshal.dump(event))
        actor = repository.actor_of(row, @session)
        actor = actor.dup.freeze if actor.is_a?(String)
        record = [row, repository.event_id(row), actor]
        if prior && record.eql?(prior)
          record = prior
        else
          seal(record)
        end
        if record.equal?(prior) && @signatures.last == previous.signature(index)
          @signatures << previous.signature(index + 1)
          @sizes << previous.record_bytes(index)
        else
          encoded=Marshal.dump(record)
          @signatures << Digest::SHA256.digest(@signatures.last + encoded).freeze
          @sizes << encoded.bytesize
        end
        @retained_bytes += @sizes.last
        @by_event[row] = [index, record]
        record
      end
      @events = @records.map(&:first)
      @records.freeze
      @signatures.freeze
      @sizes.freeze
    end

    def actor_of(event, _session = nil); @by_event.fetch(event).last[2]; end
    def event_id(event); @by_event.fetch(event).last[1]; end
    def index_of(event); @by_event.fetch(event).first; end

    def signature(count = @records.length)
      @signatures.fetch(count)
    end

    def record_at(index); @records[index]; end
    def record_bytes(index); @sizes.fetch(index); end

    private
    def seal(value)
      case value
      when Hash then value.each { |key,item| seal(key); seal(item) }
      when Array, Struct then value.each { |item| seal(item) }
      end
      value.freeze
    end
  end

  def initialize
    @lock = Mutex.new
    @generation = 0
    @entry = nil
  end

  # Reducer checkpoints precede any presentation-only pending transitions.
  # A historical view may be read without evicting the longer current prefix.
  def reduce(input, context:, identities: [])
    key = Digest::SHA256.digest(Marshal.dump([input.session, input.players, context])).freeze
    entry, ticket = @lock.synchronize { [@entry, @generation += 1] }
    count = input.events.length
    prefix = 0
    checkpoint = nil
    same_context = entry && entry.key == key && entry.identities.length == identities.length &&
      entry.identities.zip(identities).all? { |left, right| left.equal?(right) }
    if same_context && entry.count <= count
      if input.signature(entry.count) == entry.signature
        prefix = entry.count
        checkpoint = Marshal.load(entry.checkpoint)
        return checkpoint if prefix == count
      end
    end
    result = yield(checkpoint, prefix)
    signature = input.signature
    encoded = Marshal.dump(result).freeze
    @lock.synchronize do
      if ticket == @generation
        historical = same_context && entry.equal?(@entry) && @entry.count > count
        unless historical
          @entry = encoded.bytesize <= MAX_BYTES ? Entry.new(key, identities.dup.freeze, count, signature, encoded) : nil
        end
      end
    end
    result
  end
end
