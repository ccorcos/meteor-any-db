if Meteor.isServer
  @Msgs = new Mongo.Collection('msgs')
  DB.publish 'msgs', -> Msgs.find({}, {sort:{createdAt:-1}})

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
      Meteor.call('newMsg', Random.hexString(24), input.value)
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
      Msgs.insert(msg)
    else
      # Calling the the same signature of Cursor.observeChanges to add and
      # remove the subscription for latency compensation.
      fields = R.pipe(
        R.assoc('unverified', true), 
        R.omit(['_id'])
      )(msg)
      msgs.addedBefore(id, fields, msgs.docs[0]?._id or null)
      msgs.addUndo id, -> msgs.removed(id)