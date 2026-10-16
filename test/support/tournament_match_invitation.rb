# encoding: UTF-8
require_relative 'invitation_fresh_endpoint'
require_relative 'native_room_harness'
require_relative 'tournament_match_readback'
require_relative '../../lib/tournaments/match_target_guard'

# Wyłącznie SYMULACJA właścicielskiego establish+conditional-release.
# Porównanie participant.id i leave w tej pamięci NIE dowodzi gwarancji SDK.
class TournamentMatchMembership
  attr_accessor :after_establish, :release_result
  attr_reader :establish_count, :release_count, :last_receipt
  def initialize(app, broker)
    @app, @broker = app, broker
    @establish_count = @release_count = 0
  end

  def supports_owned_release?; true; end

  def establish(table:, binding:, account:, attempt_id:)
    @establish_count += 1
    status = @app.send(:establish_invited_table_transport, table)
    person = @broker.cores.fetch(table['__live_session_id']).participants[account]
    @last_receipt = { 'status' => status, 'attempt_id' => attempt_id,
      'account' => account, 'native_uuid' => table['__live_session_id'],
      'table_id' => table['__id'], 'participant_id' => person&.id,
      'membership_generation' => person&.id, 'scope' => binding.to_h['scope'] }.freeze
    after_establish&.call
    @last_receipt
  end

  def release(receipt)
    @release_count += 1
    return release_result if release_result
    core = @broker.cores.fetch(receipt['native_uuid'])
    person = core.participants[receipt['account']]
    return :superseded unless person && person.id == receipt['participant_id'] && person.id == receipt['membership_generation']
    @app.transport.deactivate_table(table_id: receipt['table_id'])
    :released
  end
end

class TournamentMatchScenario
  attr_reader :alice, :bob, :broker, :gateway, :old, :target, :invitation,
    :binding, :context, :reference, :port, :guard, :consent, :membership, :acceptance, :calls

  def initialize(game_id: 'uno', names: %w[Alice Bob], original: nil)
    @broker, @gateway = original ? original.broker : NativeLiveSessionsBroker.new, DurableNoticeGateway.new
    @alice = InvitationAppDriver.new(broker, 'Alice', gateway)
    @bob = InvitationAppDriver.new(broker, 'Bob', gateway)
    $game_room_test_user = 'Alice'
    @old = original ? original.table : alice.transport.create_room(name: 'Stary', game: 'uno', owner: 'Alice', game_options: '{}')
    raw = TournamentMatchFixture.payload(game_id: game_id, names: names)
    $game_room_test_user = 'Bob'
    @target = bob.transport.create_room(name: 'Cel', game: game_id, owner: 'Bob',
      game_options: JSON.generate(raw['options']), private_table: true)
    bob.send(:deliver_table_invitation, target, 'Alice')
    $game_room_test_user = 'Alice'
    @invitation = alice.send(:load_pending_invitations).first.fetch(:invitation)
    raw['native_uuid'], raw['table_id'] = target.values_at('__live_session_id', '__id')
    @binding = GameRoomTournaments::MatchBinding.build(raw, registry: TournamentMatchFixture.registry)
    @context = TournamentMatchFixture.context(binding)
    @reference = TournamentMatchFixture.reference.merge('app_invitation_id' => invitation.id)
    @port = TournamentMatchReadback.new(binding, context, reference)
    @guard = GameRoomTournaments::MatchTargetGuard.new(port: port, port_identity: 'fixture-authority', context: -> { context })
    @consent = guard.consent(binding: binding, invitation_ref: reference)
    @membership = TournamentMatchMembership.new(alice, broker)
    ordinary = alice.send(:invitation_acceptance)
    @calls = Hash.new(0)
    callbacks = ordinary.instance_variable_get(:@membership)
    %i[leave complete apply_role reconnect].each do |key; callback|
      callback = callbacks[key]
      callbacks[key] = ->(*args, **kwargs) { calls[key] += 1; callback.call(*args, **kwargs) }
    end
    @acceptance = GameRoomUseCases::AcceptInvitation.new(lobby: alice.instance_variable_get(:@lobby),
      transport: alice.transport, invitations: alice.instance_variable_get(:@invitations),
      membership: callbacks, user: -> { $game_room_test_user }, target_guard: guard, bound_membership: membership)
  end

  def join
    acceptance.join(invitation, current: old, binding: binding, consent: consent)
  end

  def old_present?
    core = broker.cores.fetch(old['__live_session_id'])
    !core.closed && core.participants.key?('alice')
  end

  def target_present?
    broker.cores.fetch(target['__live_session_id']).participants.key?('alice')
  end

  def change_target
    port.response = GameRoomTournaments::Publication::Data.copy(port.response)
    yield port.response['binding']
  end
end
