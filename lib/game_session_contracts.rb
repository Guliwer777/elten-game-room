require_relative 'game_snapshot'

module GameRoomSessionContracts
  GameSnapshot = Struct.new(:session, :events, keyword_init: true)
  RoomSnapshot = Struct.new(:table, :members, :bots, :observers, keyword_init: true)
  PresentationSnapshot = Struct.new(:session, :table, :replay, :members, :activity, :snapshot, :room, keyword_init: true)
  PendingWrite = Struct.new(:message_id, :packet, :sender, :writing, :uncertain, :error, keyword_init: true)

  SessionIdentity = Struct.new(:table_id, :session_id, :control_epoch, keyword_init: true) do
    def self.from_row(row)
      new(table_id: row['table_id'].to_i, session_id: (row['__id'] || row['id']).to_i,
        control_epoch: row['__control_epoch']).freeze
    end
  end

  EventRevision = Struct.new(:event_count, :latest_event_id, keyword_init: true) do
    def self.from_legacy(value)
      return value if value.is_a?(self)
      new(event_count: value[0], latest_event_id: value[1]).freeze
    end

    # Repository callers and external strategies keep the established pair.
    def to_legacy
      [event_count, latest_event_id]
    end
  end

  # A UI acknowledgement can reuse its revision only while its exact accepted
  # log is immutable. Detach that log from repository/model input before sealing
  # it; the rest of the replay remains mutable. Replacing the log or copying a
  # replay requires a new capture, even when count and final ID did not change.
  # This token is local to publication, never a substitute for commit checks.
  class ViewRevision
    attr_reader :revision

    def initialize(session:, replay:, repository:)
      @identity, @events = GameRoomSnapshot.copy([SessionIdentity.from_row(session), replay.accepted_events.to_a])
      freeze_tree(@identity, {})
      freeze_tree(@events, {})
      @revision = EventRevision.from_legacy(repository.events_revision(@events))
      replay.accepted_events = @events
      freeze
    end

    def matches?(session, replay)
      @events.equal?(replay.accepted_events) && @identity == SessionIdentity.from_row(session)
    end

    private

    def freeze_tree(value, seen)
      return if value.frozen? || seen[value.object_id]
      seen[value.object_id] = true
      case value
      when Hash then value.each { |key, item| freeze_tree(key, seen); freeze_tree(item, seen) }
      when Array, Struct then value.each { |item| freeze_tree(item, seen) }
      end
      value.freeze
    end
  end
end
