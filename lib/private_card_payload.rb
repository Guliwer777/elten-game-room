require_relative 'private_card_selection'
require_relative 'game_action_payload'

# Large selections retain the ordinary atomic payload and revision checks.
# Only the selected cards are then proved, through the same per-account
# disclosure mechanism as scoring. No partial meld is applied to the table.
module GameRoomPrivateCardPayload
  include GameRoomPrivateCardSelection

  private

  def private_secure_plan(plan, _state, _actor)
    return [:invalid, nil] unless GameRoomActionPayload.data_from_commands(plan.events, id)
    commands = plan.events.map { |event| GameRoomPrivateCards.command(event.action, event.value, operation: 'claim') }
    [:ok, GameRoomGames::ActionPlan.new(events: commands)]
  end

  def private_event_cards(event, state)
    event['__payload'] ? private_payload_cards(event['__payload'], state) : super
  end

  def private_payload_cards(_data, _state); []; end

  def private_selection_preflight?(state, event, actor)
    data = event['__payload']
    data && super &&
      data['round'] == state[:round] && data['turn'] == state[:turn]
  end
end
