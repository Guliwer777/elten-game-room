require_relative '../../support/ui' unless defined?(DuckChallengeNativeDriver)
require_relative '../../support/duck_challenge_ui'
require_relative 'challenge_audio_helpers'
require_relative '../../../lib/duck_racing/client'

module DuckClientTest
  include GameRoomTest::Assertions
  include DuckChallengeTest
  ENGINE = GameRoomDuckRacing::ChallengeEngine
  CLIENT = GameRoomDuckRacing::Client
  FINGERPRINT = 'e' * 64

  class Progress
    attr_accessor :covered
    attr_reader :closed, :form, :updates
    def initialize(&advance); @advance, @covered, @updates = advance, false, 0; end
    def attach(form); @form = form; end
    def detach; @form = nil; end
    def close; @closed = true; detach; end
    def covered?; @covered; end
    def update(background: false)
      return if @closed
      @updates += 1
      @advance.call(background)
    end
  end

  class Realtime
    attr_reader :calls, :projection, :closed, :binding
    attr_accessor :pending, :until_ms, :fail_start
    def initialize(program); @program, @calls = program, []; end
    def bind_screen(**options); @binding = options; @calls << [:bind, options]; end
    def start; !@closed; end
    def update_table_control(value); @control = value; end
    def before_wait(replay, viewer)
      @calls << [:before_wait, replay&.state&.dig(:round, :challenge, :id)]
      return false if finishing?
      @projection = GameRoomDuckRacing::RealtimeProjection.from(replay, owner: @binding[:owner])
      @active = !@projection.nil? && !@fail_start
    end
    def active?; @active && !finishing? && !@closed; end
    def finishing?; !!@until_ms; end
    def context_data; {'duck_realtime_point' => @pending}; end
    def finish_point(receipt)
      return false unless active? && receipt['id'] == @projection.id
      @calls << [:finish, receipt]
      @until_ms, @pending = @program.now_ms + 180, nil
      true
    end
    def tick
      @calls << [:tick]
      if @until_ms && @program.now_ms >= @until_ms
        @until_ms, @active, @projection = nil, false, nil
      end
    end
    def progress_frame(**_options); tick; end
    def attach_view(form, surface); @calls << [:attach, form, surface]; end
    def detach_view; @calls << [:detach]; end
    def show_settings; @calls << [:settings]; end
    def close; @calls << [:close]; @closed = true; @active = @until_ms = nil; end
  end

  class Surface
    attr_reader :spec, :presentation, :presents, :reads, :deactivations
    attr_accessor :active
    def initialize(spec)
      @spec, @pending, @presents, @reads, @deactivations, @press = spec, [], 0, 0, 0, 0
      @active = true
      present(spec.view)
    end
    def present(view)
      @presents += 1
      @presentation = GameRoomDuckRacing::ChallengePresentation.project(kind: @spec.kind, view: view, viewer: @spec.viewer)
    end
    def push(kind, **values)
      @press += 1
      @pending << {kind: kind, press_id: @press}.merge(values)
    end
    def take_input(_form); @reads += 1; result, @pending = @pending, []; result; end
    def input_active?(_form); @active; end
    def activate_input; end
    def clear_pending; @pending.clear; end
    def deactivate_input; @deactivations += 1; @pending.clear; end
  end

  class NativeSurface
    attr_accessor :on_pong_command, :on_audio_ball_command
  end

  class Game
    attr_reader :loads
    attr_accessor :resources, :load_error
    def initialize(resources); @resources, @loads = resources, 0; end
    def resources_for(_options)
      @loads += 1
      raise @load_error if @load_error
      @resources
    end
    def card_description(type); "Description of #{type}"; end
  end

  class Repository
    def actor_of(event, _session); event['actor']; end
    def event_id(event); event['__id']; end
  end

  def assert(value, message = 'Assertion failed')
    @checks = @checks.to_i + 1
    super
  end

  def resources
    @resources ||= challenge_resources.merge(fingerprint: FINGERPRINT).freeze
  end

  def make_replay(kind, phase: :playing, id: 1, players: %w[Alice Bob Charlie], participants: [0, 1], seed: 4)
    types = GameRoomDuckRacing::Challenges::BY_ID.keys
    state = GameRoomDuckRacing::Session.initial(session_id: 91, player_count: players.length, laps: 3,
      enabled_challenges: types, fingerprint: FINGERPRINT)
    race = GameRoomDuckRacing::Race.start(player_count: players.length, laps: 3, enabled_challenges: types, seed: 3)
    racers = participants.to_h { |seat| [seat, {progress: 2 + seat * 3, feathers: 18, card_count: 3, die_sides: 6, die_rolls: 0}] }
    challenge = {id: id, kind: kind, seed: seed, participants: participants,
      race_snapshot: {board_length: 30, laps: 3, racers: racers}}
    race[:phase], race[:challenge] = :challenge, challenge
    round = {challenge: challenge, phase: phase, ready: {}, created_at: 100_000, started_at: phase == :playing ? 100_000 : nil,
      last_seen: participants.to_h { |seat| [seat, 100_000] }, balances: participants.to_h { |seat| [seat, 18] }}
    if phase == :playing
      if ENGINE::SHARED.include?(kind)
        round[:engine] = ENGINE.start(challenge, resources: resources)
      elsif ENGINE::FIRST_ANSWER.include?(kind)
        round[:attempts] = {}
      elsif !ENGINE::REALTIME.include?(kind)
        round[:private] = GameRoomDuckRacing::PrivateRound.start(session_id: 91, round_id: id.to_s,
          seats: participants, started_at_ms: 100_000, reveal_timeout_ms: 90_000)
      end
    end
    state.merge!(race: race, round: round, options: {}, players: players, owner: 'Alice')
    GameRoomGames::Replay.new(players: players, winner: nil, draw: false, current_player: nil,
      accepted_events: [], history: [], state: state)
  end

  def setup_client(kind, viewer: 'Alice', phase: :playing, id: 1, transport: nil, presentation_busy: nil, session_time: nil, **options)
    @replay = make_replay(kind, phase: phase, id: id, **options)
    @program = DuckChallengeAudioTest::Program.new
    @game = Game.new(resources)
    @wrappers, @audios = [], []
    @viewer = viewer
    @client = CLIENT.new(@program, @game, transport: transport, clock: -> { @program.now_ms / 1000.0 },
      presentation_busy: presentation_busy,
      session_time: session_time || ->(_state) { 100_000 + @program.now_ms },
      audio_factory: ->(**keywords) { GameRoomDuckRacing::ChallengeAudio.new(@program, **keywords).tap { |value| @audios << value } },
      realtime_factory: -> { Realtime.new(@program).tap { |value| @wrappers << value } },
      progress_factory: ->(**keywords, &block) {
        @progress = @real_controls ? GameRoomRealtime::Progress.new(**keywords, &block) : Progress.new(&block)
      })
    @client.bind_screen(session_id: 91, table_id: 18, owner: 'Alice', viewer: viewer, members: -> { @replay.players })
    @client.start
    control
    @client.before_wait(@replay, viewer)
    attach unless @real_controls
    @client
  end

  def control
    @client.update_table_control({'__players' => @replay.players, '__table_owner' => @replay.state[:owner], '__control_epoch' => 'initial'})
  end

  def attach
    spec = @client.surface_spec(@replay, @viewer)
    @surface = spec.is_a?(GameSurfaces::DuckChallengeSpec) ? Surface.new(spec) : NativeSurface.new
    @form = Object.new
    @client.attach_view(@form, @surface)
  end

  def advance(ms, background: false)
    @program.now_ms = ms
    @client.progress_frame(background: background)
  end

  def replace
    @replay = Marshal.load(Marshal.dump(@replay))
    @replay.state[:revision] += 1
    yield @replay if block_given?
    control
    @client.before_wait(@replay, @viewer)
  end

  def request; @client.context_data['duck_action']; end
  def finish_preparation(delay_ms: ENGINE::PREPARATION_DELAY_MS)
    advance(@program.now_ms + delay_ms)
    advance(@program.now_ms + ENGINE::COUNTDOWN_MS)
    assert(!@client.local_view[:preparing], 'The countdown did not finish')
  end
  def close; @client&.close; end
  def report(name); puts "PASS #{name}: #{@checks} checks"; end
end
