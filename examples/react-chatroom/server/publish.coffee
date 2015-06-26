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