# encoding: UTF-8
require 'json'
require 'digest'
require_relative '../../../content/languages'
require_relative '../../../content/quiz_pl_wikidata'

def assert(value, message); raise message unless value; end

pack = GameRoomContent.registry.pack('quiz.wikidata.pl')
questions = pack.data.fetch('questions')
# This is an editorial baseline, not an engine compatibility requirement.
# It includes the six approved wording corrections from the 2026-10-16
# player reports, covered individually by reviewed_questions_test.rb.
# It also includes the three approved prompt-only corrections reported by
# Zuzler on 2026-10-18; answers, order and all other fields remain unchanged.
# The 2026-10-21 review corrected the Sasza Zaluska item, with its complete
# approved wording and choices checked in reviewed_questions_test.rb.
assert(Digest::SHA256.hexdigest(JSON.generate(questions.first(14887))) ==
  '639d17ef7b739a09851cd50ad19b636eb5df0663a777e24b93e5520900656aa4',
  'The existing Polish set changed while importing a community proposal')

expected = {
  'community_b96_20261014_01' => [
    'W którym podlaskim mieście kręcono sceny do filmu „Znachor” Jerzego Hoffmana?',
    'W Bielsku Podlaskim', 'Kultura'],
  'community_b96_20261014_02' => [
    'Które z tych rosyjskich miast leży na wschodnich stokach Uralu?',
    'Jekaterynburg', 'Geografia'],
  'community_b96_20261014_03' => [
    'W którym roku polski Kościół prawosławny uzyskał od Konstantynopola autokefalię, czyli niezależność?',
    '1924', 'Religia'],
  'community_b96_20261014_04' => [
    'Ile złotych pobierano z konta każdej drużyny na początku licytacji w „Awanturze o kasę” w latach 2002–2005?',
    '200 zł', 'Kultura'],
  'community_b96_20261014_05' => [
    'Z którym podlaskim miastem wiąże się tradycja pieczenia marcinka?',
    'Z Hajnówką', 'Życie codzienne'],
  'community_b96_20261014_06' => [
    'Która zupa jest szczególnie kojarzona z polską kuchnią wojskową?',
    'Grochówka', 'Życie codzienne'],
  'community_b96_20261014_07' => [
    'Kto prowadził pierwszą polską edycję „Tańca z gwiazdami”?',
    'Magda Mołek i Hubert Urbański', 'Kultura']
}
indexed = questions.to_h { |q| [q.fetch('id'), q] }
expected.each do |id, (prompt, correct, category)|
  question = indexed.fetch(id)
  assert(question.values_at('prompt', 'correct', 'category') == [prompt, correct, category], "#{id}: reviewed scope or answer changed")
  assert(question.fetch('author') == 'bratczyk96', "#{id}: contributor missing")
  assert(question.fetch('source_dataset') == 'Power Games community', "#{id}: source misattributed")
  assert(question.fetch('source').start_with?('https://'), "#{id}: fact-checking source missing")
  assert(question.fetch('source_license').include?('no separate reuse license specified'), "#{id}: an ungranted licence was assigned")
  assert(question.fetch('review_required') == false, "#{id}: unresolved item integrated")
  choices = [question.fetch('correct'), *question.fetch('wrong')]
  assert(choices.size == 4 && choices.uniq.size == 4, "#{id}: four distinct choices required")
  assert(questions.count { |q| q.fetch('prompt').downcase == prompt.downcase } == 1, "#{id}: duplicate prompt")
end
puts 'Community quiz questions: seven reviewed items, provenance and preserved editorial baseline: OK'
