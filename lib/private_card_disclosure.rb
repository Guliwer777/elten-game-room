require_relative 'private_card_ledger'

# A rule may need several hands when scoring or transferring cards. The
# ordinary session runner asks each account for its own native receipts;
# the host never reads a foreign draw. No separate worker or network loop.
module GameRoomPrivateCardDisclosure
  module_function

  def pending_cards(state, player)
    pending = state[:private_disclosure]
    cards = pending[:cards] ? pending[:cards].fetch(player) : state.fetch(pending[:zone]).fetch(player)
    cards - state[:private_public]
  end

  def complete?(state)
    state[:private_disclosure][:players].all? { |player| pending_cards(state, player).empty? }
  end

  def prepare(state, players, purpose:, zone: :hands, cards: nil)
    state[:private_disclosure] = {players: players.dup, purpose: purpose,
      zone: zone, cards: cards, resume: [state[:phase], state[:current_player]]}
    return false if complete?(state)
    state[:phase], state[:current_player] = :private_show, nil
    true
  end

  def command(state, actor)
    return nil unless state[:phase] == :private_show && state[:private_viewer].to_s.casecmp?(actor.to_s)
    player = state[:private_disclosure][:players].find { |name| name.casecmp?(actor.to_s) }
    return nil unless player
    receipts = pending_cards(state, player).filter_map { |card| GameRoomPrivateCardLedger.locate(state, actor, card) }
    first = receipts.first
    return nil unless first
    packet = receipts.select { |item| item[:draw_id] == first[:draw_id] }
    known = packet.select { |item| GameRoomPrivateCardLedger.known?(state, item) }
    unless known.empty?
      # Reusing public evidence still uses the ordinary 64-character action
      # dialect. A native batch can be much larger; disclose a bounded prefix
      # and let the existing pending-disclosure path continue the same hand.
      values = known.map { |item| item[:value] }
      value = loop do
        candidate = JSON.generate([state[:private_disclosure][:purpose], first[:draw_id], values])
        break candidate if candidate.length <= GameRoomEventProtocol::MAX_VALUE_LENGTH
        values.pop
        raise ArgumentError, 'Known private card receipt exceeds the action limit' if values.empty?
      end
      return GameRoomPrivateCards.command('private_show', value, operation:'claim')
    end
    values = packet.map { |item| item[:value] }
    GameRoomPrivateCards.command('private_show', state[:private_disclosure][:purpose], operation: 'reveal',
      pool_id: first[:pool_id], draw_id: first[:draw_id], values: values)
  end

  def apply(state, event, actor)
    pending = state[:private_disclosure]
    return false unless state[:phase] == :private_show && pending
    event = known_event(state, event, actor, pending[:purpose]) unless event['__server_pool']
    return false unless event && event['value'] == pending[:purpose]
    player = pending[:players].find { |name| name.casecmp?(actor.to_s) }
    proof = event['__server_pool']
    return false unless player && proof && proof['operation'] == 'reveal'
    pool = state[:private_pools][proof['pool_id']]
    return false unless pool && GameRoomPrivateCards.valid_reveal_values?(proof['values']) &&
      proof['values'].all? { |value| value <= pool[:cards].size }
    cards = proof['values'].map { |value| pool[:cards][value - 1] }
    return false if pending[:cards] && !(cards - pending_cards(state, player)).empty?
    GameRoomPrivateCardLedger.with_reveals(state, event, actor, hand: state.fetch(pending[:zone])[player], cards: cards) do
      state[:private_public] |= cards
      true
    end
  end

  def known_event(state, event, actor, purpose)
    data = JSON.parse(event['value'].to_s)
    return nil unless data.is_a?(Array) && data.size == 3 && data[0] == purpose
    _, id, values = data
    draw = state[:private_draws][id]
    return nil unless draw && draw[:player].casecmp?(actor.to_s) && GameRoomPrivateCards.valid_reveal_values?(values) &&
      (values - state.fetch(:private_known, {}).fetch(id, [])).empty?
    event.merge('value'=>purpose, '__server_pool'=>{'operation'=>'reveal',
      'pool_id'=>draw[:pool], 'draw_id'=>id, 'values'=>values})
  rescue JSON::ParserError
    nil
  end
end
