# Neo4j.query("MATCH (msg:MSG) RETURN msg")

if Meteor.isServer
  @Neo4j = new Neo4jDB()

  DB.publish 'msgs', 10000, () ->
    Neo4j.query """
      MATCH (msg:MSG)
      RETURN msg
      ORDER BY msg.createdAt DESC
    """

Meteor.methods
  newMsg: (text) ->
    check(text, String)
    msg = {
      _id: Random.hexString(24)
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      Neo4j.query """
        CREATE (:MSG #{Neo4j.stringify(msg)})
      """

if Meteor.isClient
  msgs = DB.subscribe('msgs')
    
  Template.main.helpers
    msgs: () -> msgs

  Template.main.events
    'click button': (e,t) ->
      input = t.find('input')
      Meteor.call 'newMsg', input.value
      input.value = ''