require 'securerandom'
require_relative 'game_event_protocol'
require_relative 'server_random_rendering'

# Public, durable draws. Rules and turn validation remain in the game. Only
# native LiveSessions metadata can authenticate a draw; packet fields cannot.
module GameRoomServerRandom
  VERSION = 1
  Command = Struct.new(:action, :value, :random_request, keyword_init: true)
  @actions = {}
  @payload_actions = {}
  @payload_integer_seeds = {}
  @payload_inputs = {}
  @prefixes = {}
  @json_actions = {}
  module_function

  def register(game, actions, prefixes: {}, json_actions: {})
    @actions[game.to_s] = actions.map(&:to_s).freeze
    @prefixes[game.to_s] = prefixes
    @json_actions[game.to_s] = json_actions
  end

  def register_payload(game, actions, integer_seed: false, inputs: {})
    register(game, [game.to_s])
    @payload_actions[game.to_s] = actions.map(&:to_s).freeze
    @payload_integer_seeds[game.to_s] = integer_seed
    @payload_inputs[game.to_s] = inputs
  end

  def actions(game)
    @actions.fetch(game.to_s, [])
  end

  def required?(game, commands)
    game = game.to_s
    if @payload_actions[game]
      data = GameRoomActionPayload.data_from_commands(commands, game)
      return payload_required?(game, data)
    end
    commands.any? do |command|
      action = GameRoomEventProtocol.command_value(command, 'action')
      fields = @json_actions.fetch(game, {})[action]
      next json_action_matches?(command, fields) if fields
      prefixes = @prefixes.fetch(game, {})[action]
      actions(game).include?(action) && (!prefixes || prefixes.any? { |prefix| GameRoomEventProtocol.command_value(command, 'value').to_s.start_with?(prefix) })
    end
  end

  def json_action_matches?(command, fields)
    value = GameRoomEventProtocol.command_value(command, 'value')
    return false unless value.is_a?(String) && value.bytesize <= 64
    data = JSON.parse(value, max_nesting: 2)
    data.is_a?(Hash) && fields.all? { |key, expected| data[key] == expected }
  rescue JSON::ParserError
    false
  end

  def accepts_request?(game, request)
    payload = @payload_actions[game.to_s]
    return true unless payload
    request['format'] == 'recipe' && request.dig('recipe', 'kind') == 'payload_seed' &&
      !!request.dig('recipe', 'integer_seed') == @payload_integer_seeds.fetch(game.to_s, false) &&
      payload_required?(game.to_s, request.dig('recipe', 'data'))
  end

  def payload_required?(game, data)
    return false unless data.is_a?(Hash)
    return true if @payload_actions.fetch(game, []).include?(data['action'])
    fields = @payload_inputs.fetch(game, {})[data['action']]
    fields && data['input'].is_a?(Hash) && fields.all? { |key, value| data['input'][key] == value }
  end

  def payload_seed_command(action:, data:)
    fields = {data: JSON.parse(JSON.generate(data.reject { |key, _| key == 'seed' }))}
    fields[:integer_seed] = true if @payload_integer_seeds[action.to_s]
    recipe_command(action: action, kind: 'payload_seed', **fields)
  end

  def command(action:, count:, sides:, keep: [], sort: false)
    request = {'version' => VERSION, 'id' => SecureRandom.uuid, 'count' => count,
      'sides' => sides, 'keep' => keep.dup, 'sort' => sort}
    raise ArgumentError, 'Invalid server dice request' unless valid_request?(request)
    Command.new(action: action.to_s, value: '', random_request: request)
  end

  def request_from(commands)
    requests = commands.filter_map { |command| GameRoomEventProtocol.command_value(command, 'random_request') }
    return nil if requests.empty?
    raise ArgumentError, 'A random action must contain exactly one draw' unless commands.length == 1 && requests.length == 1
    request = requests.first
    raise ArgumentError, 'Invalid server dice request' unless valid_request?(request)
    JSON.parse(JSON.generate(request))
  end

  def valid_request?(request)
    request.is_a?(Hash) && (request.keys.sort == %w[count id keep sides sort version] || valid_seed_request?(request) || valid_recipe_request?(request)) &&
      request['version'] == VERSION && request['id'].is_a?(String) &&
      /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(request['id']) &&
      request['count'].is_a?(Integer) && request['count'].between?(1, 20) &&
      request['sides'].is_a?(Integer) && request['sides'].between?(2, 1000) &&
      [true, false].include?(request['sort']) && request['keep'].is_a?(Array) &&
      request['keep'].length <= 20 && request['keep'].all? { |n| n.is_a?(Integer) && n.between?(1, request['sides']) } &&
      (%w[seed recipe].include?(request['format']) || ((request['count'] + request['keep'].length) * (request['sides'].to_s.length + 1) - 1 <= GameRoomEventProtocol::MAX_VALUE_LENGTH))
  end

  def valid_recipe_request?(request)
    request.keys.sort == %w[count format id keep recipe sides sort version] &&
      request.values_at('format', 'count', 'sides', 'keep', 'sort') == ['recipe', 16, 256, [], false] &&
      GameRoomServerRandomRendering.valid?(request['recipe'])
  end

  def recipe_command(action:, kind:, **fields)
    result = command(action: action, count: 16, sides: 256)
    result.random_request.merge!('format' => 'recipe', 'recipe' => {'kind' => kind}.merge(fields.transform_keys(&:to_s)))
    raise ArgumentError, 'Invalid random wire recipe' unless valid_request?(result.random_request)
    result
  end

  def text_seed_command(action:, template: '{seed}', seats: [0])
    recipe_command(action: action, kind: 'seed_text', template: template, seats: seats)
  end

  def valid_seed_request?(request)
    request.keys.sort == %w[count format id keep prefix sides sort version] &&
      request.values_at('format', 'count', 'sides', 'keep', 'sort') == ['seed', 16, 256, [], false] &&
      request['prefix'].is_a?(String) && request['prefix'].match?(/\A[1-9][0-9]{0,8}\|\z/)
  end

  def seed_command(action:, round:)
    command = command(action: action, count: 16, sides: 256)
    command.random_request.merge!('format' => 'seed', 'prefix' => "#{round}|")
    raise ArgumentError, 'Invalid server seed request' unless valid_request?(command.random_request)
    command
  end

  def native_parameters(metadata)
    if metadata.respond_to?(:server_random?)
      return nil unless metadata.server_random? && !metadata.private?
      [metadata.min, metadata.max, metadata.count]
    elsif metadata.is_a?(Hash) && metadata['origin'] == 'server' && [nil, 'public'].include?(metadata['visibility'])
      metadata['random'].is_a?(Hash) ? metadata['random'].values_at('min', 'max', 'count') : nil
    end
  end

  def decode(packet, metadata)
    parameters = native_parameters(metadata)
    return [packet, nil] unless parameters
    return nil unless packet.is_a?(Hash) && packet['context'].is_a?(Hash)
    context = packet['context']
    # The server vouches for the draw, not the client's JSON envelope.
    # Reject malformed nesting before Hash#dig can interrupt the whole read.
    return nil unless context['kind'] == 'game_action' && context['data'].is_a?(Hash)
    request = context['data']['random_request']
    return nil unless valid_request?(request)
    return nil unless parameters == [1, request['sides'], request['count']]
    values = packet['values']
    return nil unless values.is_a?(Array) && values.length == request['count'] &&
      values.all? { |n| n.is_a?(Integer) && n.between?(1, request['sides']) }
    commands = context.dig('data', 'events')
    return nil unless GameRoomEventProtocol.valid_wire_commands?(commands) && commands.length == 1 && commands[0]['value'] == ''
    canonical = JSON.parse(JSON.generate(context))
    dice = request['keep'] + values
    dice.sort! if request['sort']
    value = if request['format'] == 'recipe'
      GameRoomServerRandomRendering.render(request['recipe'], values)
    elsif request['format'] == 'seed'
      request['prefix'] + values.map { |n| (n - 1).to_s(16).rjust(2, '0') }.join
    else
      dice.join(',')
    end
    if request.dig('recipe', 'kind') == 'payload_seed'
      original = commands.first
      data = request['recipe']['data'].merge('seed' => value)
      canonical['data']['events'] = GameRoomActionPayload.commands(original['action'], data).each_with_index.map do |command, index|
        GameRoomEventProtocol.normalized(command).merge('move_id' => "#{original['move_id']}:#{index}")
      end
    else
      canonical['data']['events'][0]['value'] = value
    end
    return nil unless GameRoomEventProtocol.valid_wire_commands?(canonical['data']['events'])
    [canonical, JSON.parse(JSON.generate(request))]
  end

  def confirmation_key(event)
    request = GameRoomEventProtocol.command_value(event, 'random_request') ||
      GameRoomEventProtocol.command_value(event, '__server_random')
    action = GameRoomEventProtocol.command_value(event, 'action').to_s
    return [action, :random, request['id']] if valid_request?(request)
    [action, GameRoomEventProtocol.command_value(event, 'value').to_s]
  end

  def valid_dice_event?(event, count:, sides:, keep: [], sort: false)
    request = event['__server_random']
    return true if request == nil # historical/local actions retain their dialect
    valid_request?(request) && request.values_at('count', 'sides', 'keep', 'sort') == [count, sides, keep, sort]
  end

  def valid_recipe_event?(event, kind:, **fields)
    request = event['__server_random']
    return true if request == nil
    valid_request?(request) && request['format'] == 'recipe' &&
      request['recipe'] == {'kind' => kind}.merge(fields.transform_keys(&:to_s))
  end

  # Timed card models already validate and remove their ordinary clock
  # envelope before applying a deal. It is not part of the entropy recipe.
  def valid_text_seed_event?(event, template:, seats: [0], clock: false)
    request = event['__server_random']
    return true if request == nil
    return false unless valid_request?(request) && request['format'] == 'recipe'
    recipe = request['recipe']
    actual = recipe['template']
    return false unless actual.is_a?(String)
    if clock
      parts = actual.split('~', -1)
      return false unless parts.length == 2 && /\A[0-9a-z]+:[0-9a-z]+\z/.match?(parts.last)
      actual = parts.first
    end
    recipe.merge('template' => actual) == {'kind'=>'seed_text', 'template'=>template, 'seats'=>seats}
  end

  # Compact seed events for draws whose candidate list lives in the replay
  # (question IDs, remaining letters). No candidate list is sent over the wire.
  def text_seed_value(event, template:)
    pattern = Regexp.escape(template).sub(Regexp.escape('{seed}'), '([0-9a-f]{32})')
    match = /\A#{pattern}\z/.match(event['value'].to_s)
    match[1] if match && valid_text_seed_event?(event, template:template)
  end
end
