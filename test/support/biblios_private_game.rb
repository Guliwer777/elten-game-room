require_relative 'private_card_games'
require_relative '../../games/biblios'

def check_private_biblios_game(users)
  game = GameRoomGames::Biblios.new
  h, runners = PrivateCardGamesTest.create(game, users:users, options:{'penalty'=>'full'}, random_values:Array.new(16,8))
  assert(h.replay(users.first).state[:phase] == :allocate,
    "initial private gift not delivered #{h.replay(users.first).state.inspect}; #{h.events(users.first).inspect}")
  counts = Hash.new(0)
  returned = false
  penalised = false
  350.times do |index|
    PrivateCardGamesTest.tick(h,runners)
    first = h.replay(users.first)
    break if first.finished?
    assert(!first.state[:private_error], "private error #{first.state[:private_error]}")
    actor = first.current_player
    next unless actor
    projection_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    mine = h.replay(actor)
    puts "Biblios #{users.size}, step #{index}, events #{mine.accepted_events.size}, replay #{((Process.clock_gettime(Process::CLOCK_MONOTONIC)-projection_started)*1000).round(1)} ms" if (index % 50).zero?
    actions = game.legal_actions(mine,actor)
    assert(!actions.empty?, "no action #{mine.state[:phase]}")
    choice = if mine.state[:phase] == :pay && !penalised && mine.state[:hands][actor].size >= 2
      penalised = true
      actions.find { |a| a['cards'] == '[]' }
    elsif mine.state[:phase] == :auction
      mine.state[:high].zero? ? (actions.find { |a| a['amount'] == 1 } || actions.first) : actions.first
    elsif mine.state[:phase] == :pay
      actions.find { |a| a['cards'] != '[]' } || actions.first
    else
      actions.max_by { |a| game.bot_action_score(mine,actor,a) }
    end
    counts[mine.state[:phase]] += 1
    PrivateCardGamesTest.submit(h,runners,actor,choice)
    12.times do
      PrivateCardGamesTest.tick(h,runners)
      break unless game.send(:private_waiting?, h.replay(actor).state)
    end
    PrivateCardGamesTest.assert_private(h)
    if !returned && index >= 12
      before = h.replay(actor)
      owner = h.view(users.first)
      owner.transfer_ownership(owner.participants.find { |p| p.user == users.last })
      runners[actor].close
      h.view(actor).leave
      h.add_client(actor)
      assert(h.join(actor), 'return rejected')
      runners[actor] = runner_for(h,actor)
      assert(h.replay(actor).state[:hands][actor] == before.state[:hands][actor], 'return changed library')
      returned = true
    end
    h.users.each do |viewer|
      view = h.replay(viewer)
      game.surface_spec(view,viewer)
      game.game_shortcuts(view,viewer)
      event = view.accepted_events.last
      game.describe_event(event,h.repositories[viewer],view,viewer) if event
    end
  end
  final = h.replay(users.first)
  assert(final.finished?, "game not finished #{final.state[:phase]} #{counts.inspect}")
  assert(final.accepted_events.size == h.events(users.first).size, 'valid event rejected')
  assert(counts[:allocate] > 10 && counts[:take] > 3 && counts[:church] > 0 && counts[:pay] > 0 && penalised, 'coverage missing')
  PrivateCardGamesTest.assert_private(h)
  runners.each_value(&:close)
  puts "PASS private Biblios #{users.size}: #{counts.inspect}, #{final.accepted_events.size} events, host/return, penalty, scoring"
end
