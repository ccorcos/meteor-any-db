



Msgs = createModel 'msgs'
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

sub = Msgs.subscribe



class DBModel
  constructor: (@name, obj) ->
    {
      pollAndDiff
      query
      getCursor
      @insertDB
      @insertSub
    } = obj
    if Meteor.isServer
      if pollAndDiff
        DB.publish(@name, pollAndDiff, query)
      else
        DB.publish(@name, getCursor)
    else
      @sub = createSubsctiptionCursor(name)
  subscribe:  ->
    @sub.start.apply(@sub, arguments)
  stop:  ->
    @sub.stop.apply(@sub, arguments)
  observe: ->
    @sub.observe.apply(@sub, arguments)
  observeChanges: ->
    @sub.observeChanges.apply(@sub, arguments)
  fetch: ->
    @sub.fetch.apply(@sub, arguments)


    