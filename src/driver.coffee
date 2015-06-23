debug = console.log.bind(console)
# debug = (->)

{
  map
  assoc
  apply
  omit
  clone
  merge
  split
  findIndex
  propEq
} = R


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

# DDP "change" messages will set fields to undefined if they are meant to be unset.
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L172
# So we can call `extendDeep` then `deleteUndefined` update changes.
deleteUndefined = (obj) ->
  for k,v of obj
    if isPlainObject(v)
      deleteUndefined(v)
    else if v is undefined
      delete obj[k]
  return obj

# Its not particularly clear in the DDP spec if the fields object contains nested EJSON objects.
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#messages-2
# All I know is that they pass it directly into `$set` which, for nested objects, requires '.' separated strings.
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L179
# This function simply translates an object of "fields" with '.' separated keys for nested
# fields and translates that into a nested object.

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

# The DDP spec doesnt talk much about this but it looks like DDP sends funny ID's for the 
# documents. They use the `mongo-id` package but I get an error when I use it, so I copied it.
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L139
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo-id/id.js#L80[]

parseId = (id) ->
  if id is ""
    return id
  else if id is '-'
    return undefined
  else if id.substr(0, 1) is '-'
    return id.substr(1)
  else if id.substr(0, 1) is '~'
    # numbered id's should remain strings!
    return JSON.parse(id.substr(1)).toString()
  else
    return id

# This function parses the subId and before from ddb fields.
parseDDPFields = (msg) ->
  [subId, before] = msg.fields[DB.name]?.split('.') or []
  if before is "null" then before = null
  return [subId, before]


# global on both client and server.
# DB.name will be used as an identifier in DDP messages.
@DB = {}
DB.name = 'ANY_DB'

# Meteor does poll-and-diff does internally
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/polling_observe_driver.js#L176
# We can use their internal package that does a bunch of hard stuff
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/diff-sequence/diff.js#L7

if Meteor.isServer
  DB.publish = (name, ms, query) ->
    # name:  name of the publication, so you can do DB.subscribe(name, args...)
    # ms:    millisecond interval to poll-and-diff.
    # query: a function called with args from DB.subscribe that returns a 
    #        collection of documents that must contain an `_id` field!

    # a friendly warning in case they thought it was seconds.
    if ms < 1000
      console.warn("Polling every #{ms} ms. This is pretty damn fast!")

    # When you return a Mongo.Cursor from Meteor.publish, it calls this function:
    # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L302
    # This is how we'll publish documents.

    Meteor.publish name, (subId, args...) ->
      pub = this

      # pass the arguments to the query function
      poll = () -> apply(query, args)

      # DDP doesnt support ordered document collections yet
      # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#procedure-2
      # so we don't have addedBefore. However, we could be doing some advanced sorting in Neo4j or something
      # so we'll want to support that. Thus we'll add a key, DB.name to all position-based callbacks as a shim.
      # The format of the message will be the subscription id and the position separated by a dot.

      # Get the initial data. Add them in order to the end.
      docs = poll()
      for doc in docs
        id = doc._id
        fields = omit(["_id"], doc)
        # null means its at the end of the collection
        pub.added(DB.name, id, fields)
        move = {}
        move[DB.name] = "#{subId}.null"
        pub.changed(DB.name, id, move)

      # Tell the client that the subscription is ready
      pub.ready()

      # The observer needs to publish to the correct database name
      # and send the subId and position.
      observer =
        addedBefore: (id, fields, before) ->
          fields = fields or {}
          pub.added(DB.name, id, fields)
          # if we add two documents with different keys, the change
          # isnt recognized, so we sent it over as a change.
          @movedBefore(id, before)
        movedBefore: (id, before) ->
          fields = {}
          fields[DB.name] = "#{subId}.#{before}"
          pub.changed(DB.name, id, fields)
        changed: (id, fields) ->
          pub.changed(DB.name, id, fields)
        removed: (id) ->
          pub.removed(DB.name, id)

      # MDG already did the hard work for us :)
      pollAndDiff = ->
        newDocs = poll()
        DiffSequence.diffQueryChanges(true, docs, newDocs, observer)
        docs = newDocs

      # Set the poll-and-diff interval
      intervalId = Meteor.setInterval(pollAndDiff, ms)

      # clean up
      pub.onStop ->
        Meteor.clearInterval(intervalId)



# We should be able to subscribe from server to server as well
# but that will require some stuff with Fibers. Right now, its just
# on the client.
if Meteor.isClient

  # Key-value store for all data passed through this API. 
  # This simply uses the _id field as a key. There may be
  # more efficient ways of storing this data...
  DB.docs = {}

  # All subscriptions, keyed by the subId. 
  DB.subscriptions = {}


  # DBSubscription represents a single subscription on the client. It must 
  # be able to funciton like `Meteor.subcribe`, `Mongo.Collection`, and  `Mongo.Cursor`.
  # When data is added to DB.docs, its also passed by reference to the subscriptions.
  # This way, any changes are reflected immediately. Any data returned from here
  # ought to be cloned so developers can mess with the internal mutable structures. 
  # We need these mutable structures because DDP sends only the minimal amount of changes.

  class DBSubscription
    constructor: (@subId) ->
      i = 0
      @observerCounter = -> i++
      @results = []
      @changeObservers = {}
      @observers = {}
      @dep = new Tracker.Dependency()

    subscribe: (args) ->
      @sub = Meteor.subscribe.apply(Meteor, args)

    stop: ->
      @sub.stop()

    observeChanges: (callbacks) ->
      # add all the initial docs
      for doc in clone(@results)
        callbacks.addedBefore(doc._id, omit(["_id", doc]), null)
      i = @observerCounter()
      @changeObservers[i] = callbacks
      return {stop: => delete @changeObservers[i]}

    observe: (callbacks) ->
      # add all the initial docs
      length = 0
      for doc in clone(@results)
        callbacks.addedAt(doc, length, null)
        length++
      i = @observerCounter()
      @observers[i] = callbacks
      return {stop: => delete @observers[i]}

    updateAdded: (doc, index, before) ->
      for key, observer of @changeObservers
        observer.addedBefore(doc._id, omit(['_id'], doc), before)
      for key, observer of @observers
        observer.addedAt(doc, index, before)

    updateMoved: (doc, fromIndex, toIndex, before) ->
      for key, observer of @changeObservers
        observer.movedBefore(doc._id, before)
      for key, observer of @observers
        observer.movedTo(doc, fromIndex, toIndex, before)

    indexOf: (id) ->
      findIndex(propEq('_id', id), @results)

    fetch: ->
      @dep.depend()
      return clone(@results)

    # registerStore DDP updates will call these functions
    # to update the subscriptions.
    addedBefore: (doc, before) ->
      if before is null
        @results.push(doc)
        @updateAdded(clone(doc), @results.length-1, before)
      else
        i = @indexOf(before)
        if i < 0 then throw new Error("Expected to find before _id")
        @results.splice(i,0,doc)
        @updateAdded(clone(doc), i, before)
      @dep.changed()
    
    movedBefore: (doc, before) ->
      id = doc._id
      fromIndex = @indexOf(id)
      if fromIndex < 0
        # to add a document to a subscription, we add then move.
        @addedBefore(doc, before)
        return
      @results.splice(fromIndex, 1)
      if before is null
        @results.push(doc)
        @updateMoved(clone(doc), fromIndex, @results.length-1, before)
      else
        toIndex = @indexOf(before)
        if toIndex < 0 then throw new Error("Expected to find before _id: #{before}")
        @results.splice(toIndex, 0, doc)
        @updateMoved(clone(doc), fromIndex, toIndex, before)
      @dep.changed()
    
    changed: (id, newDoc, oldDoc, fields) ->
      i = @indexOf(id)
      if i < 0 then throw new Error("Expected to find id: #{id}")
      for key, observer of @changeObservers
        observer.changed(id, fields)
      for key, observer of @observers
        observer.changedAt(newDoc, oldDoc, i)
      @dep.changed()
    
    removed: (id) ->
      i = @indexOf(id)
      # if i < 0 then throw new Error("Expected to find id")
      if i >= 0
        [oldDoc] = @results.splice(i, 1)
        for key, observer of @changeObservers
          observer.removed(id)
        for key, observer of @observers
          observer.removedAt(clone(oldDoc), i)
        @dep.changed()

    reset: ->
      # clear all observers
      for doc in @results
        for key, observer of @changeObservers
          observer.removed(doc._id)
        for key, observer of @observers
          observer.removedAt(doc, 0)
      @results = []
      @dep.changed()

  DB.reset = ->
    debug "reset"
    DB.docs = {}
    for subId, sub of DB.subscriptions
      sub.reset()

  # Get the DDP connection so we can register a store and listen to messages
  DB.connection = if Meteor.isClient then Meteor.connection else Meteor.server
  
  # I'm simply copying how MDG does it with Mongo.
  # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp-client/livedata_connection.js#L1343
  # This is poorly/un- documented...

  DB.connection.registerStore DB.name,
    beginUpdate: (batchSize, reset) ->
      # Missing some kind of optimization here.
      # if batchSize > 1 or reset
      #   # pauseObservers
      if reset
        DB.reset()

    update: (msg) ->
      id = parseId(msg.id)
      doc = DB.docs[id]

      debug("msg", msg)

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
        if doc then throw new Error("Expected not to find a document already present for an add")
        # Docs aren't passed to subscriptions this way. 
        # They are added globally, and then "moved"
        # [subId, before] = parseDDPFields(msg)
        # doc = omit([DB.name], msg.fields)
        doc = msg.fields
        doc._id = id
        DB.docs[id] = doc
        # pass the doc by reference!
        # DB.subscriptions[subId].addedBefore(doc, before)
        return

      if msg.msg is 'removed'
        if not doc then throw new Error("Expected to find a document already present for removed")
        delete DB.docs[id]
        # if it simply cleared a publication, this should come though
        # as a change. removed means totally removed.
        for key, sub of DB.subscriptions
          sub.removed(id)
        return

      if msg.msg is 'changed'
        if not doc then throw new Error("Expected to find a document to change")
        [subId, before] = parseDDPFields(msg)
        if subId
          # this could potentially be adding the document
          DB.subscriptions[subId].movedBefore(doc, before)
        fields = omit([DB.name], msg.fields)
        if R.keys(fields).length > 0
          oldDoc = clone(doc)
          extendDeep(doc, fields2Obj(fields))
          # undefined values are effectively unsetting the key
          deleteUndefined(DB.docs[id])
          newDoc = clone(doc)
          DB.subscriptions[subId].changed(id, newDoc, oldDoc, fields)
        return

      throw new Error("I don't know how to deal with this message");

    endUpdate: ->
      # resumeObservers

    # // Called around method stub invocations to capture the original versions
    # // of modified documents.
    # saveOriginals: function () {
    #   self._collection.saveOriginals();
    # },
    # retrieveOriginals: function () {
    #   return self._collection.retrieveOriginals();
    # }


  # The client must tell the server a subscription id. This is used to sort out
  # the documents coming in over DDP. We'll use a simple counter to generate ids.

  pubCount = 0
  subCounter = -> pubCount++

  DB.subscribe = (name, args...) ->
    subId = subCounter()

    collection = new DBSubscription(subId)
    DB.subscriptions[subId] = collection

    args.unshift(subId)
    args.unshift(name)
    sub = Meteor.subscribe.apply(Meteor, args)
    collection.sub = sub

    return collection
