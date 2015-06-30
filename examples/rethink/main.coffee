if Meteor.isServer
  @Rethink = new RethinkDB()

  unless Rethink.tableExists('msgs')
    console.log "Creating 'msgs' table..."
    Rethink.run(r.tableCreate('msgs'))
    console.log "...done"

  unless Rethink.hasIndex('createdAt', r.table('msgs'))
    Rethink.run(r.table('msgs').indexCreate('createdAt'))

  DB.publish 
    name: 'msgs'
    ms: 10000
    query: () ->
      Rethink.fetch(r.table('msgs').orderBy({index: r.desc('createdAt')}))
    depends: ->
      ['msgs']

if Meteor.isClient
  # The arguments are the same as you're used to with
  # Meteor.subscribe. Only, you then have to call `start()`.
  @msgs = DB.createSubscription('msgs')

  # Start the subscription in an autorun and it will stop
  # when Template.onDestroyed
  Template.main.onRendered ->
    @autorun -> msgs.start()
  
  # msgs is a Cursor!
  Template.main.helpers
    msgs: () -> msgs

  Template.main.events
    'click button': (e,t) ->
      input = t.find('input')
      # When calling a method, you have to make sure to initialize
      # the id on the client and send it to the server so the client
      # and server can stay in sync.
      id = DB.newId()
      Meteor.call 'newMsg', id, input.value, (err, result) -> 
        if err then msgs.handleUndo(id)
      input.value = ''

# Both client and server
Meteor.methods
  newMsg: (id, text) ->
    check(id, String)
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      Rethink.run(r.table('msgs').insert(msg))
      DB.triggerDeps('msgs')
    else
      # Calling the the same signature of Cursor.observeChanges to add and
      # remove the subscription for latency compensation.
      fields = R.pipe(
        R.assoc('unverified', true), 
        R.omit(['_id'])
      )(msg)
      msgs.addedBefore(id, fields, msgs.docs[0]?._id or null)
      msgs.addUndo id, -> msgs.removed(id)
