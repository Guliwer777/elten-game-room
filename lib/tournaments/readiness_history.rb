# encoding: UTF-8
require_relative 'readiness_journal'

module GameRoomTournaments
  # Ograniczony odczyt 128 pierwotnych intencji jednego konta i celu. Nie woła
  # store/claim/resolve ani prywatnego API Service. Nie tworzy brakujących celów.
  class ReadinessHistory
    C = ReadinessContract
    def initialize(directory:, context:, identity:)
      @directory, @context, @identity = directory, context, identity
    end

    def records(scope:, match_ref:)
      C.target!(scope, match_ref)
      expected = C.frozen_copy(@context.call)
      C.fields!(expected, %w[account backend_identity runtime_id runtime_epoch auth_epoch backend_epoch cancelled])
      unless expected['backend_identity'].eql?(@identity) && scope['backend_identity'].eql?(@identity) &&
          expected['cancelled'].equal?(false) && %w[runtime_epoch auth_epoch backend_epoch].all? { |key| C::Data.integer?(expected[key],1) }
        raise C::Blocked, :incomplete_context
      end
      guard = -> { raise C::Blocked, :context_changed unless @context.call.eql?(expected) }
      io = lambda do |cleanup: false, &block|
        primary = nil
        begin
          guard.call unless cleanup
          block.call
        rescue Exception => error
          primary = error
          raise error, cause: error.cause
        ensure
          begin
            guard.call unless cleanup
          ensure
            raise primary, cause: primary.cause if primary
          end
        end
      end
      journal = ReadinessJournal.new(directory: @directory, scope: scope, match_ref: match_ref,
        account: expected['account'], io: io)
      return [].freeze unless io.call { File.directory?(LocalFilesystem.native(File.dirname(journal.path))) }
      journal.with_attempt { |store| store.records }
    end
  end
end
