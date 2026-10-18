require_relative 'mahjong_table_game'

module MahjongMatchFixture
  include MahjongTableGameTest
  def match_between_fixture
    game = MahjongTableGameTest::Game.new
    repo = MahjongTableGameTest::Repository.new
    session = {'id'=>45, 'players'=>%w[Alice Bob Carol Dave], 'options'=>JSON.generate('variant'=>'mcr', 'seats'=>4, 'match_winds'=>1)}
    context = GameRoomGames::ActionContext.new(session_id: 45, random_source: MahjongTableGameTest::RandomSource.new)
    events = []
    current = game.replay(session, events, repo)
    600.times do
      break if current.state[:phase] == :between_hands
      actor = game.active_actors(current).first
      selection = game.automatic_action(current, actor, context: context) || game.table_bot_selection(current, actor)
      status, plan = game.action_for(selection, current, actor, context: context)
      raise "Fixture action failed: #{status}" unless status == :ok
      number = events.length + 1
      event = table_event(number, plan.events.first, actor: actor).merge('sequence'=>number, 'created_at'=>1_800_000_000)
      events << event
      current = game.incremental_replay(current, session, [event], repo)
    end
    raise 'Fixture did not reach its between-hand barrier' unless current.state[:phase] == :between_hands
    {game: game, repo: repo, session: session, context: context, events: events, replay: current}
  end
end
