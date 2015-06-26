
Meteor.methods
  newRoom: (id, name) ->
    check(id, String)
    check(name, String)
    room = {
      _id: id
      name: name
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
      Rooms.addedBefore(id, fields, Rooms.docs[0]?._id or null)
      Rooms.addUndo id, -> Rooms.removed(id)
      selectRoom(id)

  newMsg: (roomId, id, text) ->
    check(id, String)
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      # throw new Meteor.Error(99, "Test optimistic UI")
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
      Msgs[roomId].addedBefore(id, fields, Msgs[roomId].docs[0]?._id or null)
      Msgs[roomId].addUndo id, -> Msgs[roomId].removed(id)