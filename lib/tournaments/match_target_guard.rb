# encoding: UTF-8
require 'securerandom'
require_relative 'match_binding'

module GameRoomTournaments
  # Klientowy port read_target NIE istnieje w NativeSDK 3.0.4. Właściciel
  # dostarcza go jawnie po negocjacji, z zaufaną tożsamością spoza payloadu.
  # Musi czytać bieżący kompletny cel/grant i autentyczną własną zgodę (K06),
  # nie discovery/cache. read_id koreluje ten odczyt; nie nadaje autorytetu.
  # To odczyt, NIE serwerowe compare+write ani gwarancja atomowego join/leave.
  class MatchTargetGuard
    Data = Publication::Data
    Consent = Struct.new(:binding, :invitation_ref, :context, :owner, keyword_init: true)
    REFERENCE = %w[app_invitation_id native_invitation_id generation expires_at receipt_revision].map(&:freeze).freeze

    def initialize(port:, port_identity:, context:)
      @port, @port_identity, @context = port, Data.freeze_tree(Data.copy(port_identity)), context
      @owner = Object.new.freeze
    end

    # Wywołujący przechwytuje zgodę PRZED dialogiem, nie dopiero w join.
    # context jest zaufanym czytnikiem runtime, nie polem wiadomości. Musi mieć
    # rosnącą epokę dla KAŻDEJ zmiany konta/backendu/runtime/grantu/anulowania,
    # również A→B→A między dwoma odczytami. Bez tej integracji brak capability.
    def consent(binding:, invitation_ref:)
      return nil unless binding.instance_of?(MatchBinding)
      reference = reference_copy(invitation_ref)
      context = context_copy
      return nil unless reference && context && context['scope'].eql?(binding.to_h['scope'])
      Consent.new(binding: binding, invitation_ref: reference, context: context, owner: @owner).freeze
    end

    def check(binding:, consent:, table:, invitation_id:, user:, invitation: nil)
      return :coordination_unavailable unless configured_port?
      unless binding.instance_of?(MatchBinding) && consent.instance_of?(Consent) &&
          consent.frozen? && consent.owner.equal?(@owner) && consent.binding.equal?(binding)
        return :invalid_binding
      end
      data = binding.to_h
      people = data['players'] + data['observers']
      unless people.any? { |person| person['account'] == consent.context['account'] && person['username'].eql?(user) }
        return :context_changed
      end
      return :target_changed unless target_matches?(table, data, invitation_id, consent, invitation)
      return :context_changed unless current?(consent)
      read_id = SecureRandom.uuid
      # Brak rescue wokół portu: ProgramError i jego bezpośredni cause przechodzą.
      response = @port.read_target(binding: data, invitation_ref: consent.invitation_ref, read_id: read_id)
      return :context_changed unless current?(consent)
      return :target_changed unless target_matches?(table, data, invitation_id, consent, invitation)
      validate_response(response, binding: data, consent: consent, read_id: read_id)
    end

    private

    def configured_port?
      @port && Data.text!(@port_identity, bytes: 256)
    rescue Publication::Invalid
      false
    end

    def target_matches?(table, data, invitation_id, consent, invitation)
      # Czytamy aktualny nośnik także PO I/O, nie tylko wcześniejsze argumenty.
      # Descriptor zachowuje własne uchwyty; nie kopiujemy ani nie zamrażamy go.
      return false if invitation && (!invitation.table.equal?(table) || !invitation.id.eql?(invitation_id))
      Hash === table && table['__id'].eql?(data['table_id']) &&
        table['__live_session_id'].eql?(data['native_uuid']) &&
        invitation_id.eql?(consent.invitation_ref['app_invitation_id'])
    end

    def current?(consent)
      context_copy.eql?(consent.context)
    end

    def context_copy
      value = Data.copy(@context.call)
      return nil unless Hash === value && value.keys.sort == %w[scope account runtime_id epoch cancelled].sort
      return nil unless value['cancelled'].equal?(false) && Data.integer?(value['epoch'], 1)
      Data.text!(value['account'], bytes: 256, length: 128)
      Data.text!(value['runtime_id'], bytes: 256)
      Data.freeze_tree(value)
    rescue Publication::Invalid
      nil
    end

    def reference_copy(value)
      value = Data.copy(value)
      return nil unless Hash === value && value.keys.sort == REFERENCE.sort
      return nil unless Data.integer?(value['expires_at'], 1) && Data.integer?(value['app_invitation_id'], 1)
      (REFERENCE - %w[expires_at app_invitation_id]).each { |key| Data.text!(value[key], bytes: 256) }
      Data.freeze_tree(value)
    rescue Publication::Invalid
      nil
    end

    def validate_response(raw, binding:, consent:, read_id:)
      response = Data.copy(raw)
      return :incomplete_readback unless Hash === response
      return :unconfirmed_target unless response['status'].eql?('confirmed')
      return :coordination_unavailable unless response['capabilities'].eql?({ 'match_target_read' => 1 })
      expected = { 'contract_version' => 1, 'port_identity' => @port_identity,
        'scope' => binding['scope'], 'account' => consent.context['account'],
        'binding' => binding, 'read_id' => read_id,
        'receipt' => consent.invitation_ref.merge('state' => 'accepted') }
      return :target_changed unless expected.all? { |key, value| response[key].eql?(value) }
      :ok
    rescue Publication::Invalid
      :incomplete_readback
    end
  end
end
