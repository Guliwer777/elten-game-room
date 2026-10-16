require_relative '../support/quiz_creator_native'
require_relative '../support/quiz_contributions'
require_relative '../../lib/quiz_contributions/views'
include QuestionContributionTest
Q=GameRoomQuizContributions
NativeOptionTest.language='en'
files=QuestionContributionTest::Files.new
user='guest'
repo=Q::Repository.new(app_uuid:'audit',user:user,current_user:-> {user},client:Object.new,api:files)
saved=repo.save(sample.merge('snapshot'=>SecureRandom.uuid))
original=files.rows.first.dup
bad=original.dup
bad.id=99
bad.meta='{broken'
files.rows.unshift(bad)
rows=repo.list
assert(rows.size==2 && rows.first['damaged'],'Damaged draft was hidden or hid the valid draft')
assert(repo.read(rows.last)['items']==sample['items'],'Healthy cloud-only draft could not be opened')
views=Q::Views.new(Object.new)
assert(views.draft_label(rows.first).include?('damaged'),'Bad entry is not visibly marked')
assert(!views.draft_label(rows.last).include?('damaged'),'Healthy entry falsely marked')
rejects {repo.read(rows.first)}
assert(files.rows.size==2,'Opening damaged draft deleted data')
ref=rows.first
bad.meta='{}'
rejects {repo.delete(ref)}
assert(files.rows.size==2,'Changed damaged record was deleted with a stale selection')
ref=repo.list.first
bad.meta=original.meta
rejects {repo.delete(ref)}
assert(files.rows.size==2,'Repaired record was deleted using old damaged metadata')
# A fabricated damaged reference must not bypass ordinary draft validation.
forged=ref.merge('fingerprint'=>repo.send(:fingerprint,bad))
rejects {repo.delete(forged)}
bad.meta='null'
ref=repo.list.first
files.fail=[:delete,false]
rejects(IOError) {repo.delete(ref)}
assert(files.rows.size==2,'Failed delete removed a draft')
assert(repo.delete(ref),'Explicit deletion failed')
assert(files.rows.size==1 && files.rows.first.id==saved['resource_id'],'Wrong draft removed')
assert(repo.read(repo.list.first)['items']==sample['items'],'Healthy draft changed')
%w[title kind count language].each do |key|
  bad=original.dup
  bad.id=100
  meta=JSON.parse(original.meta)
  meta[key]=[]
  bad.meta=JSON.generate(meta)
  files.rows.unshift(bad)
  assert(repo.list.first['damaged'],"Invalid #{key} escaped isolation")
  files.rows.shift
end
bad.meta="\xFF".force_encoding(Encoding::UTF_8)
files.rows.unshift(bad)
ref=repo.list.first
assert(ref['damaged'],'Invalid metadata encoding escaped isolation')
assert(repo.delete(ref),'Explicit deletion of invalid metadata failed')
bad.meta='{}'
files.rows.unshift(bad)
ref=repo.list.first
user='other'
rejects(Q::Unavailable){repo.delete(ref)}
assert(files.rows.size==2,'Account change deleted a draft')
user='guest'
module Session
  def self.name;'guest';end
end
Dir.mktmpdir('damaged-draft-ui-') do |directory|
  storage=QuestionContributionTest::Storage.new(directory)
  drafts=Q::Drafts.new(storage,user:user,current_user:-> {user})
  program=EltenGameRoom.allocate
  controller=Q::Controller.new(program,drafts:drafts,repository:repo,delivery:Q::Delivery.new(repo,messages:QuestionContributionTest::Mailbox.new))
  controller.define_singleton_method(:task) do |_title,**_options,&job|
    job.call(nil)
  rescue Q::Error=>error
    @views.notice(error.message)
    nil
  end
  pick=->(index){->(form){form.fields.first.index=index;form.accept_button.trigger(:press)}}
  cancel=->(form){form.cancel_button.trigger(:press)}
  delete=->(form) do
    form.fields.first.index=0
    menu=Menu.new
    form.fields.first.context(menu,false)
    menu.items.find{|item|item[3]==:del}.fetch(1).call
  end
  steps=[pick.call(0), ->(form) {
    assert(form.fields.first.text.include?('damaged'),'Damaged entry opened an editor instead of an explanation')
    form.accept_button.trigger(:press)
  },pick.call(1), ->(form) {
    assert(form.fields.first.options.first=='Add a question','Healthy set did not open')
    cancel.call(form)
  },delete,pick.call(0), ->(form) {
    assert(files.rows.size==2,'Declining deletion removed the file')
    delete.call(form)
  },pick.call(1), ->(form) {
    assert(form.fields.first.options.size==1 && !form.fields.first.options.first.include?('damaged'),'Healthy draft disappeared from the library')
    cancel.call(form)
  }]
  Form.driver=->(form){(steps.shift || raise('Unexpected creator dialog')).call(form)}
  controller.creator
  assert(steps.empty?,'Creator did not finish the native navigation scenario')
  assert(files.rows.size==1 && drafts.list.empty?,'Deleting damaged metadata touched healthy/local drafts')
end
puts 'PASS damaged cloud draft isolation, healthy read, native library/open/delete/cancel, metadata changes, repair and account isolation'
