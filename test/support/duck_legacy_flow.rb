require_relative '../../games/duck_racing'

# A recorded pre-compact start: only omit the new protocol marker. All later
# actions, transport, workers and replay use current production code. This
# retains coverage for resuming an already saved, multi-page private attempt.
class DuckLegacyFlowGame < GameRoomGames::DuckRacing
  def action_for(selection, replay, actor, context: nil)
    status, plan = super
    return [status, plan] unless status == :ok && selection.to_h.transform_keys(&:to_s)['action'] == 'start'
    rows = plan.events.map { |command| {'action' => command.action, 'value' => command.value} }
    repository = Object.new
    repository.define_singleton_method(:actor_of) { |*, **| actor }
    data = nil
    GameRoomActionPayload.each(rows, id, repository, {}) { |value, *_| data = value }
    raise 'Missing start in legacy fixture' unless data && data.delete('challenge_flow') == 2
    [:ok, GameRoomGames::ActionPlan.new(events: GameRoomActionPayload.commands(id, data))]
  end
end
