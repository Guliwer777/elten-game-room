require_relative '../support/clock_event_contract'
require_relative '../../games/audio_ball'

# Delay only delivery of the already-prepared native start command. The
# server stamps the real record later than the founder captured the epoch.
NativeLiveSessionsBroker::View.prepend(Module.new do
  def stack_push(packet, **options)
    if packet['kind'] == 'game_started' && (delayed = Thread.current[:audio_ball_start_delay])
      Thread.current[:audio_ball_start_delay] = nil
      delayed.call
    end
    super
  end
end)

observations = []
[[0, 0, 0], [1, 0, 0], [20, 0, 0], [20, 60, 0], [20, 0, 60], [20, 60, 60]].each do |latency, prior, during|
  ClockEventContract.with_server_time do |time|
    Thread.current[:audio_ball_start_delay] = -> { time.call(1000 + latency) }
    f = ClockEventContract::Fixture.new(GameRoomGames::AudioBall.new,
      users: %w[Alice Bob], options: {'sets_to_win' => 2})
    initial = f.snapshot.session
    assert(initial['created_at'] == 1000 && initial['__server_started_at'] == 1000 + latency,
      'The real prepared start request was not delayed')
    f.submit('Alice')
    # Audio Ball has no Save command. These explicit native freeze boundaries
    # additionally exercise replay robustness; the first three cases are the
    # normally reachable start-latency defect, without any freeze operation.
    if prior.positive?
      time.call(1002 + latency)
      f.freeze('Alice', true)
      time.call(1002 + latency + prior)
      f.freeze('Alice', false)
    end
    time.call(1010 + latency + prior)
    7.times do |index|
      f.context('Alice').local_data = {'audio_ball_point' => "#{index}:0"}
      f.submit('Alice')
    end
    set_snapshot = f.snapshot
    ending = set_snapshot.events.last
    assert(f.replay.state[:sets] == [1, 0], 'The native points did not complete a set')
    assert(ending['created_at'] == 1010 + latency + prior && ending['__clock_offset'] == prior,
      'The set event lost its original native timestamp or scoped offset')
    if during.positive?
      time.call(1011 + latency + prior)
      f.freeze('Alice', true)
      time.call(1011 + latency + prior + during)
      f.freeze('Alice', false)
    end
    owner = f.h.view('Alice')
    owner.transfer_ownership(owner.participants.find { |participant| participant.user == 'Bob' })
    f.h.as('Bob') { f.h.transports.fetch('Bob').room_snapshot(f.h.table) }
    [4, 5].each do |elapsed|
      time.call(1010 + latency + prior + during + elapsed)
      current = f.snapshot('Bob')
      replay = f.replay('Bob')
      assert(current.events.first(set_snapshot.events.length) == set_snapshot.events,
        'Later pause or ownership transfer rewrote accepted event metadata')
      assert(replay.state[:set_resume_at] == 1015, 'Set deadline is not in the founder game epoch')
      assert(f.h.users.all? { |user| f.replay(user).state[:set_resume_at] == 1015 },
        'Clients disagree about the cold set deadline')
      context = f.h.as('Bob') { f.context('Bob') }
      context.local_data = {'audio_ball_point' => '7:1'}
      selection = {'kind' => 'command', 'action' => 'audio_ball_point', 'point' => '7:1'}
      expected = elapsed == 5
      assert((f.game.action_for(selection, replay, 'Bob', context: context).first == :ok) == expected,
        'Planner is early or late at the real five-second set boundary')
      assert(!f.game.automatic_action(replay, 'Bob', context: context).nil? == expected,
        'Automatic persistence disagrees with the set deadline')
      repository = f.h.repositories.fetch('Bob')
      inserted = f.h.as('Bob') do
        repository.append_events(session: current.session,
          sequence: repository.next_sequence(current.session, current.events),
          events: [GameRoomGames::EventCommand.new(action: 'audio_ball_point', value: '7:1')],
          actor: 'Alice', controller: true)
      end
      after = f.snapshot('Bob')
      assert(after.events.last(inserted.length) == inserted, 'Writer ACK disagrees with full projection')
      f.h.users.each do |user|
        projected = f.replay(user)
        assert(projected.accepted_events.include?(inserted.last) == expected,
          "Replay #{user} disagrees with the logical set boundary")
        assert(projected.state[:scores] == (expected ? [0, 1] : [0, 0]), 'Rejected point changed the new set')
      end
      observations << [latency, prior, during, elapsed, context.now, expected]
    end
  ensure
    Thread.current[:audio_ball_start_delay] = nil
  end
end
puts "PASS Audio Ball set clock: #{observations.size} native epoch/pause/owner/ACK boundaries; no live accounts"
