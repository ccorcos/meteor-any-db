if Meteor.isServer
  @Neo4j = new Neo4jDB()

  DB.publish
    name: 'chatrooms'
    query: ->
      Neo4j.query """
        MATCH (room:ROOM)
        RETURN room
        ORDER BY room.createdAt DESC
      """
    depends: ->
      ['chatrooms']

  DB.publish
    name: 'msgs'
    query: (roomId) ->
      Neo4j.query """
        MATCH (room:ROOM {_id:"#{roomId}"})-->(msg:MSG)
        RETURN msg
        ORDER BY msg.createdAt DESC
      """
    depends: (roomId) -> 
      ["chatroom:#{roomId}"]
    

if Meteor.isClient
  Session.setDefault('roomId', null)
  Session.setDefault('msgs', [])

  @subs = {}
  subs.rooms = DB.createSubscription('chatrooms')

  # This step is a little funky to be honest. It would be
  # super convenient if we could say Session.get('msgs', subs.msgs)
  # but that will rip off any functions including observeChanges.
  # Thus we need another autorun to watch changes
  Template.main.onRendered ->
    # start the rooms immediately
    @autorun -> 
      subs.rooms.start()
    # watch for the roomId to change
    @autorun -> 
      roomId = Session.get('roomId')
      if roomId
        subs.msgs = DB.createSubscription('msgs', roomId)
        # subscription will automatically be stopped since 
        # we're in an autorun
        subs.msgs.start()
        # another autorun to watch for changes
        Tracker.autorun ->
          Session.set('msgs', subs.msgs.fetch())

  Template.main.helpers
    rooms: () -> subs.rooms
    msgs: () -> Session.get('msgs')
    isCurrentRoom: (roomId) -> Session.equals('roomId', roomId)
    currentRoom: (roomId) -> Session.get('roomId')

  Template.main.events
    'click .room': ->
      Session.set('roomId', @_id)
    'click .newRoom': (e,t) ->
      Meteor.call('newRoom', Random.hexString(24))
    'click .newMsg': (e,t) ->
      elem = t.find('input')
      input = elem.value
      Meteor.call('newMsg', Session.get('roomId'), Random.hexString(24), input)
      elem.value = ''

Meteor.methods
  newRoom: (id) ->
    check(id, String)
    room = {
      _id: id
      createdAt: Date.now()
    }
    if Meteor.isServer
      Neo4j.query("CREATE (:ROOM #{Neo4j.stringify(room)})")
      DB.triggerDeps('chatrooms')
    else
      fields = R.pipe(
        R.assoc('unverified', true), 
        R.omit(['_id'])
      )(room)
      subs.rooms.addedBefore(id, fields, subs.rooms.docs[0]?._id or null)
      subs.rooms.addUndo id, -> subs.rooms.removed(id)
      Session.set('roomId', id)
      

  newMsg: (roomId, id, text) ->
    check(id, String)
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      Neo4j.query """
        MATCH (room:ROOM {_id:"#{roomId}"})
        CREATE (room)-[:OWNS]->(:MSG #{Neo4j.stringify(msg)})
      """
      DB.triggerDeps("chatroom:#{roomId}")
    else
      fields = R.pipe(
        R.assoc('unverified', true), 
        R.omit(['_id'])
      )(msg)
      subs.msgs.addedBefore(id, fields, subs.msgs.docs[0]?._id or null)
      subs.msgs.addUndo id, -> subs.msgs.removed(id)