# Neo4j.query("MATCH (msg:MSG) RETURN msg")

if Meteor.isServer
  @Neo4j = new Neo4jDB()

  DB.publish 'msgs', 10000, () ->
    Neo4j.query """
      MATCH (msg:MSG)
      RETURN msg
      ORDER BY msg.createdAt DESC
    """


createModel 'msgs'
  pollAndDiff: 10 # seconds
  query: () ->
    Neo4j.query """
      MATCH (msg:MSG)
      RETURN msg
      ORDER BY msg.createdAt DESC
    """
  insertDB: (id, text) ->
    check(id, String)
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    Neo4j.query """
      CREATE (:MSG #{Neo4j.stringify(msg)})
    """
  insertSub: (id, text) ->
    check(id, String)
    check(text, String)
    action = (list) ->
      msg = {
        _id: id
        text: text
        createdAt: Date.now()
      }
      R.insert(msg, list)
    undo = (list) ->
      R.filter(R.complement(R.propEq('_id', id)), list)
    return {action, undo}





Meteor.methods
  newMsg: (id, text) ->
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      
    if Meteor.isClient
      msgs.insert(msg)

if Meteor.isClient
  @msgs = DB.subscribe('msgs')

    
  Template.main.helpers
    msgs: () -> msgs

  Template.main.events
    'click button': (e,t) ->
      input = t.find('input')
      Meteor.call 'newMsg', Random.hexString(24), input.value
      input.value = ''