require_relative 'private_card_ledger'

# Reuse the ordinary reducer once a round's cards are public, before scoring.
module GameRoomPrivateCardRoundAudit
  using GameRoomLocalization::Translations
  module_function

  def begin_round(state)
    state[:private_round_start] = Marshal.load(Marshal.dump(state.reject { |key, _| key.to_s.start_with?('private_') }))
    state[:private_round_actions] = []
  end

  def initial_state(state)
    audit = Marshal.load(Marshal.dump(state[:private_round_start]))
    audit[:hands] = state[:players].to_h { |player| [player, []] }
    state[:private_draws].each_value do |draw|
      next unless draw[:initial]
      return nil unless draw[:used].size == draw[:count]
      cards = state[:private_pools].fetch(draw[:pool])[:cards]
      audit[:hands][draw[:player]].concat(draw[:used].map { |value| cards[value - 1] })
    end
    audit
  end

  def reject_round(state, event, repository, history)
    state[:private_error] = :invalid_round
    state[:phase], state[:current_player], state[:winner] = :private_error, nil, nil
    state[:draw] = false if state.key?(:draw)
    state[:winners] = [] if state.key?(:winners)
    state[:scores] = state[:private_round_start][:scores].dup
    history.reject! { |entry| entry.event_id == repository.event_id(event) && [:score, :round_result, :result].include?(entry.kind) }
    history << GameRoomGames::HistoryEntry.new(key: "private_error:#{repository.event_id(event)}",
      event_id: repository.event_id(event), actor: '', kind: :private_error,
      text: _("The server deck is inconsistent. This game cannot continue."))
  end
end
