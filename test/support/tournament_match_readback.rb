# encoding: UTF-8
require_relative 'tournament_match_data'
require_relative '../../lib/tournaments/match_binding'

# Symulacja przyszłego autorytetu; NIE testuje serwerowej atomowości ani ACL.
class TournamentMatchReadback
  attr_accessor :response, :during_read
  attr_reader :calls
  def initialize(binding, context, reference)
    @calls = []
    @response = { 'status' => 'confirmed', 'contract_version' => 1,
      'port_identity' => 'fixture-authority', 'scope' => binding.to_h['scope'],
      'account' => context['account'], 'binding' => binding.to_h,
      'capabilities' => { 'match_target_read' => 1 },
      'receipt' => reference.merge('state' => 'accepted') }
  end

  def read_target(binding:, invitation_ref:, read_id:)
    @calls << [binding, invitation_ref, read_id]
    during_read&.call
    GameRoomTournaments::Publication::Data.copy(response.merge('read_id' => read_id))
  end
end

module TournamentMatchFixture
  def self.reference
    { 'app_invitation_id' => 123, 'native_invitation_id' => 'native-invite-1',
      'generation' => 'invitation-generation-1', 'expires_at' => 2_000_000_000,
      'receipt_revision' => 'consent-r1' }
  end

  def self.context(binding)
    { 'scope' => binding.to_h['scope'], 'account' => 'alice', 'runtime_id' => 'runtime-1',
      'epoch' => 1, 'cancelled' => false }
  end
end
