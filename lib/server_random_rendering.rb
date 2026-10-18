require_relative 'game_random'
require_relative 'game_action_payload'

# These small, deterministic wire recipes turn server entropy into the same
# event dialect the game already replays. They do not execute rules or choose
# a player's action, and never call a local random source while sending.
module GameRoomServerRandomRendering
  module_function

  def valid?(recipe)
    return false unless recipe.is_a?(Hash)
    case recipe['kind']
    when 'seed_text'
      template = recipe['template']
      seats = recipe['seats']
      recipe.keys.sort == %w[kind seats template] && template.is_a?(String) &&
        template.length <= 64 && template.scan('{seed}').length == 1 &&
        template.scan('{dealer}').length <= 1 &&
        template.gsub('{seed}', '').gsub('{dealer}', '').match?(/\A[0-9a-z|~:,]*\z/) &&
        seats.is_a?(Array) && seats.length.between?(1, 8) && seats.uniq == seats &&
        seats.all? { |seat| seat.is_a?(Integer) && seat.between?(0, 7) } &&
        template.gsub('{seed}', '0' * 32).gsub('{dealer}', '0').length <= 64
    when 'cat_tail', 'monopoly_roll', 'first_server'
      recipe.keys == ['kind']
    when 'payload_seed'
      data = recipe['data']
      (recipe.keys.sort == %w[data kind] ||
        (recipe.keys.sort == %w[data integer_seed kind] && recipe['integer_seed'] == true)) &&
        data.is_a?(Hash) && !data.key?('seed') &&
        data['action'].is_a?(String) && JSON.generate(data).bytesize <= 512
    else
      false
    end
  end

  def render(recipe, values)
    raise ArgumentError, 'Invalid random wire recipe' unless valid?(recipe)
    seed = values.map { |value| (value - 1).to_s(16).rjust(2, '0') }.join
    random = Random.new(seed.to_i(16))
    case recipe['kind']
    when 'payload_seed'
      recipe['integer_seed'] ? seed.to_i(16) : seed
    when 'seed_text'
      seats = recipe.fetch('seats')
      dealer = seats[seed.to_i(16) % seats.length]
      recipe['template'].gsub('{seed}', seed).gsub('{dealer}', dealer.to_s)
    when 'cat_tail'
      roll = random.rand(1..8)
      roll == 8 ? "8|#{random.rand(2).zero? ? 'minus' : 'plus'}" : roll.to_s
    when 'monopoly_roll'
      "#{random.rand(1..6)},#{random.rand(1..6)},#{seed}"
    when 'first_server'
      random.rand(2).to_s
    end
  end
end
