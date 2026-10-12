require_relative "../support/audio_ball_client"
require_relative "../support/realtime_channel"

class ScopedMatchSession < ChannelSession
  def on_reliable(&block); @reliable = block; end
  def deliver_reliable(user, data)
    @reliable.call(ChannelMessage.new(ChannelParticipant.new(99, user), data))
  end
end

class RealtimeMatchScopeTest
  include GameRoomTest::Assertions

  TYPES = [
    [GameRoomPong::Client, GameRoomGames::AxelPong, PongTestAudio, "axel_pong"],
    [GameRoomAudioBall::Client, GameRoomGames::AudioBall, AudioBallTestAudio, "audio_ball"]
  ].freeze

  def assert(value, message = "Assertion failed")
    @checks = (@checks || 0) + 1
    super
  end

  def build(type, viewer: "Alice", native: false, **options)
    client_type, game_type, audio_type, = type
    channels, activity = [], []
    transport = Object.new
    transport.define_singleton_method(:note_realtime_activity) { |table, session| activity << [table, session] }
    factory = lambda do |**args|
      channel = if native
        GameRoomRealtime::EventChannel.new(**args, work_factory: -> { ChannelWork.new },
          event_work_factory: -> { ChannelWork.new })
      else
        AudioBallTestChannel.new({}, **args)
      end
      channels << channel
      channel
    end
    client = client_type.new(Program.new, game_type.new, clock: -> { 4.0 },
      audio: audio_type.new, transport: transport, channel_factory: factory)
    client.bind_screen(session_id: 300, table_id: 20, owner: "Alice", viewer: viewer,
      members: -> { %w[Alice Bob Watcher] }, **options)
    [client, channels, activity]
  end

  def match(client); client.instance_variable_get(:@match); end

  def run
    TYPES.each do |type|
      clients = []
      begin
        legacy = Digest::SHA256.hexdigest("GameRoom:#{type.last}:20:300")[0, 24]
        plain, = build(type)
        explicit_nil, = build(type, match_scope: nil)
        clients.concat([plain, explicit_nil])
        assert_equal(legacy, match(plain))
        assert_equal(legacy, match(explicit_nil))

        first, first_channels, first_activity = build(type, match_scope: "duck:round-1")
        peer, = build(type, viewer: "Bob", match_scope: "duck:round-1")
        second, second_channels, second_activity = build(type, match_scope: "duck:round-2")
        clients.concat([first, peer, second])
        assert_equal(match(first), match(peer), "Same challenge did not produce a common identity")
        assert_equal(3, [legacy, match(first), match(second)].uniq.length)
        assert_equal(match(first), first.instance_variable_get(:@base_match))
        [first, peer, second].each do |client|
          assert_equal(20, client.instance_variable_get(:@activity_table))
          assert_equal(300, client.instance_variable_get(:@activity_session))
        end
        first.send(:note_play_activity)
        second.send(:note_play_activity)
        assert_equal([[20, 300]], first_activity)
        assert_equal([[20, 300]], second_activity)

        # The scope remains part of the base identity after the same control
        # epoch is applied to two separate challenges in one LiveSession.
        bases = [match(first), match(second)]
        [first, second].each do |client|
          client.update_table_control('__control_epoch' => 'initial', '__table_owner' => 'Alice')
          client.update_table_control('__control_epoch' => 'handover', '__table_owner' => 'Watcher')
          client.send(:note_play_activity)
        end
        assert_equal(Digest::SHA256.hexdigest("#{bases[0]}:handover")[0, 24], match(first))
        assert_equal(Digest::SHA256.hexdigest("#{bases[1]}:handover")[0, 24], match(second))
        assert(match(first) != match(second), "A common control epoch erased challenge isolation")
        assert_equal([2, 2], [first_channels.size, second_channels.size])
        assert(first_channels.first.connected? == false && second_channels.first.connected? == false)
        assert_equal([[20, 300], [20, 300]], first_activity)
        assert_equal([[20, 300], [20, 300]], second_activity)

        # Scope content is consumed at binding, not held as a mutable caller
        # reference. UTF-8 and binary representations of the same bytes agree.
        scope = +"żółw:1"
        owned, = build(type, match_scope: scope)
        bytes, = build(type, match_scope: scope.b)
        clients.concat([owned, bytes])
        identity = match(owned)
        scope.replace("another")
        assert_equal(identity, match(owned))
        assert_equal(identity, match(bytes))
      ensure
        clients.each(&:close)
      end

      ["", 1, false, :challenge, [], {}].each do |invalid|
        calls = []
        client = type[0].new(Program.new, type[1].new, audio: type[2].new,
          channel_factory: ->(**args) { calls << args })
        assert_raises(ArgumentError) do
          client.bind_screen(session_id: 300, table_id: 20, owner: "Alice", viewer: "Alice",
            members: -> { [] }, match_scope: invalid)
        end
        assert_equal([], calls)
        assert_equal(false, client.instance_variable_defined?(:@activity_session))
        client.close
      end

      native_isolation(type)
    end
    puts "PASS realtime optional match scope: #{@checks} checks"
  end

  def native_isolation(type)
    previous, = build(type, native: true, match_scope: "duel-1")
    current, channels, = build(type, native: true, match_scope: "duel-2")
    channel = channels.first
    channel.enable_events("scope-contract", routing: :peers)
    endpoint = ChannelEndpoint.new("Alice")
    channel.instance_variable_set(:@endpoint, endpoint)
    session = ScopedMatchSession.new("same-native-epoch", "Alice", %w[Alice Bob Watcher])
    channel.__send__(:attach, session)
    encode = lambda do |identity, kind, sequence|
      GameRoomRealtime::Protocol.encode(match: identity, epoch: channel.epoch, sequence: sequence,
        kind: kind, body: {"r" => 0, "action" => "serve", "side" => 1, "turn" => 1})
    end
    # Same pair, real table/session and even equal transport epoch: packets
    # from the previous challenge must still fail the native channel filter.
    session.deliver_reliable("Bob", encode.call(match(previous), "event", 1))
    session.deliver("Bob", encode.call(match(previous), "input", 1))
    assert_equal([], channel.take_events)
    assert_equal({}, channel.take_packets)
    session.deliver_reliable("Bob", encode.call(match(current), "event", 1))
    session.deliver("Bob", encode.call(match(current), "input", 1))
    assert_equal(1, channel.take_events.size)
    assert_equal(["bob"], channel.take_packets.keys)
    previous.close
    session.deliver_reliable("Bob", encode.call(match(current), "event", 2))
    assert_equal(1, channel.take_events.size)
    assert(channel.connected?, "Closing the previous challenge closed the new channel")
  ensure
    previous&.close
    current&.close
  end
end

RealtimeMatchScopeTest.new.run
