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
  Session.setDefault('msgs', null)

  @rooms = DB.createSubscription('chatrooms')

  Template.main.onRendered ->
    @autorun -> 
      rooms.start()
    @autorun -> 
      msgs = DB.createSubscription('msgs', Session.get('roomId'))
      Session.set('msgs', msgs)

  Template.main.helpers
    rooms: () -> rooms
    msgs: () -> Session.get('msgs')

  Template.main.events
    'click .newRoom': (e,t) ->
      Meteor.call('newRoom', Random.hexString(24))
    'click .newMsg': (e,t) ->
      elem = t.find('input.msg')
      input = elem.value
      Meteor.call('newMsg', Random.hexString(24), input)
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
    else
      fields = R.pipe(
        R.assoc('unverified', true), 
        R.omit(['_id'])
      )(room)
      rooms.addedBefore(id, fields, rooms.docs[0]?._id or null)
      msgs.addUndo id, -> msgs.removed(id)
      Session.set('roomId', id)

  newMsg: (id, text) ->
    check(id, String)
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      Neo4j.query("CREATE (:MSG #{Neo4j.stringify(msg)})")
    else
      fields = R.pipe(
        R.assoc('unverified', true), 
        R.omit(['_id'])
      )(msg)
      msgs.addedBefore(id, fields, msgs.docs[0]?._id or null)
      msgs.addUndo id, -> msgs.removed(id)