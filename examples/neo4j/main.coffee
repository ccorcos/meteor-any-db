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
  newMsg: (id, text) ->
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      # this worked in a previous commit
      
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