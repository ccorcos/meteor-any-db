{map, assoc, apply, omit, clone, merge, split, findIndex, propEq} = R

isPlainObject = (x) ->
  Object.prototype.toString.apply(x) is "[object Object]"

mergeDeep = (dest, obj) ->
  newDest = clone(dest)
  for k,v of obj
    if isPlainObject(v)
      newDest[k] = mergeDeep(newDest[k] or {}, v)
    else
      newDest[k] = clone(v)
  return newDest

extendDeep = (dest, obj) ->
  for k,v of obj
    if isPlainObject(v)
      dest[k] = extendDeep(dest[k] or {}, v)
    else
      dest[k] = v
  return dest

deleteUndefined = (obj) ->
  for k,v of obj
    if isPlainObject(v)
      deleteUndefined(v)
    else if v is undefined
      delete obj[k]
  return obj


fields2Obj = (fields) ->
  dest = {}
  for key,value of fields
    keys = key.split('.').reverse()
    if keys.length is 1
      dest[key] = value
    else
      obj = {}
      prevObj = obj
      i = 0
      while keys.length > 1
        tmp = {}
        prevObj[keys.pop()] = tmp
        prevObj = tmp
        i++
      prevObj[keys.pop()] = value
      extendDeep(dest, obj)
  return dest

parseId = (id) ->
  if id is ""
    return id
  else if id is '-'
    return undefined
  else if id.substr(0, 1) is '-'
    return id.substr(1)
  else if id.substr(0, 1) is '~'
    return JSON.parse(id.substr(1))
  else
    return id

# References:

# Diffing
# https://github.com/meteor/meteor/blob/devel/packages/diff-sequence/diff.js#L7
# https://github.com/meteor/meteor/blob/devel/packages/mongo/polling_observe_driver.js#L176

# Publish
# https://github.com/meteor/meteor/blob/devel/packages/mongo/collection.js#L302

# Subscribe
# https://github.com/meteor/meteor/blob/devel/packages/ddp-client/livedata_connection.js#L480
# https://github.com/meteor/meteor/blob/devel/packages/ddp-client/livedata_connection.js#L433
# https://github.com/meteor/meteor/blob/devel/packages/mongo/collection.js#L108


# how to handle pubId?
# how to handle addedBefore, etc
# how to handle method stubs?

# WHAT THE FUCK is this duplicate id business?
# get the ids to change. then see what we can do about multiple publications. 



@DB = {}
DB.name = 'DB'

if Meteor.isServer

  DB.publish = (name, ms, query) ->
    # poll and diff every ms
    if ms < 1000
      console.warn("Polling every #{ms} ms. This is pretty damn fast!")

    Meteor.publish name, (pubId, args...) ->
      pub = this
      poll = () -> apply(query, args)

      # Get the initial data. Add them in order to the end.
      docs = poll()
      for doc in docs
        id = doc._id
        fields = omit(["_id"], doc)
        fields[DB.name] = "#{pubId}.null"
        pub.added(DB.name, id, fields)

      # Tell the client that the subscription is ready
      pub.ready()

      # The observer needs to publish to the correct database name
      observer =
        addedBefore: (id, fields, before) ->
          fields = fields or {}
          fields[DB.name] = "#{pubId}.#{before}"
          pub.added(DB.name, id, fields)
        movedBefore: (id, before) ->
          fields = {}
          fields[DB.name] = "#{pubId}.#{before}"
          pub.changed(DB.name, id, fields)
        changed: (id, fields) ->
          pub.changed(DB.name, id, fields)
        removed: (id) ->
          pub.removed(DB.name, id)

      pollAndDiff = ->
        newDocs = poll()
        DiffSequence.diffQueryChanges(true, docs, newDocs, observer)
        docs = newDocs

      # Set the poll-and-diff interval
      intervalId = Meteor.setInterval(pollAndDiff, ms)

      # clean up
      pub.onStop ->
        Meteor.clearInterval(intervalId)



class DBSubscription
  constructor: (@pubId) ->
    i = 0
    @count = -> i++
    @results = []
    @observers = {}
    @dep = new Tracker.Dependency()

  observeChanges: (callbacks) ->
    # add all the initial docs
    for doc in @results
      callbacks.addedBefore(doc._id, omit(["_id", doc]), null)
    i = @count()
    @observers[i] = callbacks
    return {stop: => delete @observers[i]}

  fetch: ->
    @dep.depend()
    return @results

  # these must not mutate the documents so they are in sync
  # with the global document cache.
  addedBefore: (doc, before) ->
    if before is null
      @results.push(doc)
    else
      i = findIndex(propEq('_id', before), @results)
      if i < 0
        throw new Error("Expected to find before _id")
      @results.splice(i,0,doc)
    for key, observer in @observers
      observer.addedBefore(doc._id, omit(['_id'], doc), before)
    @dep.changed()
  
  movedBefore: (id, before) ->
    console.log "move #{id} before #{before}, #{JSON.stringify(R.pluck('_id',@results))}"
    console.log "#{findIndex(propEq('_id', id), @results)}, #{findIndex(propEq('_id', before), @results)}"
    
    i = findIndex(propEq('_id', id), @results)
    if i < 0 then throw new Error("Expected to find id: #{id}")
    [doc] = @results.splice(i,1)

    console.log "spliced, #{JSON.stringify(R.pluck('_id',@results))}"
    if before
      i = findIndex(propEq('_id', before), @results)
      if i < 0
        throw new Error("Expected to find before _id: #{before}")
      @results.splice(i,0, doc)
    else
      @results.push(doc)
    console.log "inserted, #{JSON.stringify(R.pluck('_id',@results))}"

    for key, observer in @observers
      observer.movedBefore(id, before)
    @dep.changed()
  
  changed: (id, fields) ->
    for key, observer in @observers
      observer.changed(id, fields)
    @dep.changed()
  
  removed: (id) ->
    i = findIndex(propEq('_id', id), @results)
    if i < 0
      throw new Error("Expected to find id")
    @results.splice(i,1)
    for key, observer in @observers
      observer.removed(id)
    @dep.changed()

  reset: ->
    @results = []
    @dep.changed()



# Should be able to do this on the server as well with Fibers
if Meteor.isClient
  DB.connection = if Meteor.isClient then Meteor.connection else Meteor.server

  DB.subscriptions = {}

  DB.reset = ->
    DB.docs = {}
    for collection in DB.subscriptions
      collection.reset()

  pubCount = 0
  count = -> pubCount++

  DB.subscribe = (name, args...) ->
    pubId = count()

    collection = new DBSubscription(pubId)
    DB.subscriptions[pubId] = collection

    args.unshift(pubId)
    args.unshift(name)
    sub = Meteor.subscribe.apply(Meteor, args)
    collection.sub = sub

    return collection

  DB.docs = {}
  
  # https://github.com/meteor/meteor/blob/devel/packages/ddp-client/livedata_connection.js#L1343

  DB.connection.registerStore DB.name,
    beginUpdate: (batchSize, reset) ->
      # if batchSize > 1 or reset
      #   # pauseObservers
      # if reset
      #   # clear the database
      if reset
        DB.reset()

    update: (msg) ->
      id = parseId(msg.id)
      doc = DB.docs[id]

      console.log("msg", msg)

      # this is a pseudo-ddp message for latency compensation
      # if msg.msg is 'replace'
      #   {replace} = msg
      #   if not replace
      #     if doc
      #       delete DB.docs[id]
      #   else if not doc
      #     DB.docs[id] = replace
      #   else
      #     extendDeep(doc, replace)
      #   return

      if msg.msg is 'added'
        if doc
          throw new Error("Expected not to find a document already present for an add")
        [pubId, before] = msg.fields[DB.name]?.split('.') or []
        if before is "null" then before = null
        doc = omit([DB.name], msg.fields)
        doc._id = id
        DB.docs[id] = doc
        DB.subscriptions[pubId].addedBefore(doc, before)
        return

      if msg.msg is 'removed'
        if not doc
          throw new Error("Expected to find a document already present for removed")
        delete DB.docs[id]
        DB.subscriptions[pubId].removed(id)
        return

      if msg.msg is 'changed'
        if not doc
          throw new Error("Expected to find a document to change")
        [pubId, before] = msg.fields[DB.name]?.split('.') or []
        if before is "null" then before = null
        if pubId
          DB.subscriptions[pubId].movedBefore(id, before)
        fields = omit([DB.name], msg.fields)
        if R.keys(fields).length > 0
          extendDeep(doc, fields2Obj(fields))
          # undefined values are effectively unsetting the key
          deleteUndefined(DB.docs[id])
          DB.subscriptions[pubId].changed(id, fields)
        return

      throw new Error("I don't know how to deal with this message");

    endUpdate: ->
      # resume

    # // Called at the end of a batch of updates.
    # endUpdate: function () {
    #   self._collection.resumeObservers();
    # },

    # // Called around method stub invocations to capture the original versions
    # // of modified documents.
    # saveOriginals: function () {
    #   self._collection.saveOriginals();
    # },
    # retrieveOriginals: function () {
    #   return self._collection.retrieveOriginals();
    # }

  # http://docs.meteor.com/#/full/random
  # Random.hexString(24)




        


