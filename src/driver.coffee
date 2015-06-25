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


counter = () ->
  i = 0
  ->
    i += 1
    i %= 100000000000
    return i

isPlainObject = (x) ->
  Object.prototype.toString.apply(x) is "[object Object]"

isNumber = (x) ->
  Object.prototype.toString.apply(x) is "[object Number]"

mergeDeep = (dest, obj) ->
  newDest = clone(dest)
  for k,v of obj
    if isPlainObject(v)
      newDest[k] = mergeDeep(newDest[k] or {}, v)
    else
      newDest[k] = clone(v)
  return newDest

# extendDeep = (dest, obj) ->
#   for k,v of obj
#     if isPlainObject(v)
#       dest[k] = extendDeep(dest[k] or {}, v)
#     else
#       dest[k] = v
#   return dest

# DDP "change" messages will set fields to undefined if they are meant to be unset.
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L172
# So we can call `extendDeep` then `deleteUndefined` update changes.
deleteUndefined = (x) ->
  obj = clone(x)
  for k,v of obj
    if isPlainObject(v)
      deleteUndefined(v)
    else if v is undefined
      delete obj[k]
  return obj

changeDoc = (doc, fields) ->
  deleteUndefined(mergeDeep(doc, fields))

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

# It appears DDP doesnt do very well with nested key-values.
# https://forums.meteor.com/t/how-to-publish-nested-fields-that-arent-arrays/6007
# https://github.com/meteor/meteor/issues/4615

obj2Fields = (obj) ->
  dest = {}
  for key,value of obj
    if isPlainObject(value)
      deeperFields = obj2Fields(value)
      for k,v of deeperFields
        dest["#{key}.#{k}"] = v
    else
      dest[key] = clone(value)
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

# global on both client and server.
# DB.name will be used as an identifier in DDP messages.
@DB = {}
DB.name = 'ANY_DB'

# Meteor does poll-and-diff does internally
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/polling_observe_driver.js#L176
# We can use their internal package that does a bunch of hard stuff
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/diff-sequence/diff.js#L7

if Meteor.isServer
  
  salter = counter()

  # sets the position of the doc for the subId to the fields object.
  addPosition = R.curry (subId, before, fields) ->
    # we have to salt the position value so merge-box doesnt kill
    # the message as a repeat value.
    salt = salter()
    R.assocPath([DB.name, subId], "#{salt}.#{before}", fields)

  # return an observer that publishes ordered data to subscribers
  createObserver = (pub, subId) ->
    # DDP doesnt support ordered document collections yet
    # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#procedure-2
    # so we don't have addedBefore. However, we could be doing some advanced sorting in Neo4j or something
    # so we'll want to support that. Thus we'll add a key, DB.name to all position-based callbacks as a shim.
    # The format of the message will be the subscription id and the position separated by a dot.

    # The observer needs to publish to the correct database name
    # and send the subId and position.
    addedBefore: (id, fields, before) ->
      fields = R.pipe(
        addPosition(subId, before)
        obj2Fields
      )(fields or {})
      pub.added(DB.name, id, fields)
      debug "added", subId, id, fields
    movedBefore: (id, before) ->
      fields = addPosition(subId, null, {})
      pub.changed(DB.name, id, fields)
      debug "moved", subId, id, fields
    changed: (id, fields) ->
      pub.changed(DB.name, id, fields)
      debug "changed", subId, id, fields
    removed: (id) ->
      pub.removed(DB.name, id)
      debug "removed", subId, id

  DB.pollAndDiffPublish = (name, ms, query) ->
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

      observer = createObserver(pub, subId)
      
      docs = []

      # MDG already did the hard work for us :)
      pollAndDiff = ->
        newDocs = poll()
        DiffSequence.diffQueryChanges(true, docs, newDocs, observer)
        docs = newDocs

      # Initial poll and tell the client that the subscription is ready
      pollAndDiff()
      pub.ready()

      # Set the poll-and-diff interval
      intervalId = Meteor.setInterval(pollAndDiff, ms)

      # clean up
      pub.onStop ->
        Meteor.clearInterval(intervalId)

  DB.publishCursor = (name, getCursor) ->
    Meteor.publish name, (subId, args...) ->
      pub = this
      cursor = apply(getCursor, args)
      observer = createObserver(pub, subId)
      cursor.observeChanges(observer)
      pub.ready()

  DB.publish = (name, msOrFunc) ->
    if isNumber(msOrFunc)
      DB.pollAndDiffPublish.apply(DB, arguments)
    else
      DB.publishCursor.apply(DB, arguments)








# We should be able to subscribe from server to server as well
# but that will require some stuff with Fibers. Right now, its just
# on the client.
if Meteor.isClient

  # All subscriptions, keyed by the subId. 
  DB.subscriptions = {}

  # DBSubscription represents a single subscription on the client. It must 
  # be able to funciton like `Meteor.subcribe`, `Mongo.Collection`, and  `Mongo.Cursor`.
  # You call it with the arguments to the subscription. Then you can call start and 
  # stop on that subscription. You can observe and observeChanges with it. You can 
  # fetch() with it. And the nice thing is that it is also an observer, so you can
  # call addedBefore, movedBefore, changed, and removed to update it!

  subCounter = counter()
  createSubscription = (name, args...) ->
    subId = counter()
    sub = new DBSubscriptionCursor(subId, name, args)
    DB.subscriptions[subId] = sub
    return sub

  DB.reset = ->
    debug "reset"
    for subId, sub of DB.subscriptions
      sub.reset()

  class DBSubscriptionCursor
    constructor: (@subId, @name, @args) ->
      @docs = []
      @docIds = {}
      @dep = new Tracker.Dependency()
      @observerCounter = counter()
      @changeObservers = {}
      @observers = {}

    start: ->
      @sub = Meteor.subscribe.apply(Meteor, R.insert(@name, @subId, @args))

    stop: ->
      @sub?.stop?()

    fetch: ->
      @dep.depend()
      return clone(@docs)

    observeChanges: (callbacks) ->
      # add all the initial docs
      for doc in clone(@docs)
        callbacks.addedBefore(doc._id, omit(["_id", doc]), null)
      i = @observerCounter()
      @changeObservers[i] = callbacks
      return {stop: => delete @changeObservers[i]}

    observe: (callbacks) ->
      # add all the initial docs
      length = 0
      for doc in clone(@docs)
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

    updateChanged: (newDoc, oldDoc, fields, index)->
      for key, observer of @changeObservers
        observer.changed(newDoc._id, fields)
      for key, observer of @observers
        observer.changedAt(newDoc, oldDoc, index)

    updateRemoved: (doc, index) ->
      for key, observer of @changeObservers
        observer.removed(doc._id)
      for key, observer of @observers
        observer.removedAt(clone(doc), index)

    indexOf: (id) ->
      findIndex(propEq('_id', id), @docs)
  
    # registerStore DDP updates will call these functions to update
    # the subscriptions.
    addedBefore: (_id, fields, before, noUpdate=false) ->
      doc = merge({_id}, fields)
      @docIds[_id] = true
      if before is null
        @docs = append(doc, @docs)
        @updateAdded(clone(doc), @docs.length-1, before)
      else
        i = @indexOf(before)
        if i < 0 then throw new Error("Expected to find before _id, #{before}")
        @docs = clone(@docs)
        @docs.splice(i,0,doc)
        @updateAdded(clone(doc), i, before)
      unless noUpdate
        @dep.changed()

    movedBefore: (id, before, noUpdate=false) ->
      fromIndex = @indexOf(id)
      if fromIndex < 0 then throw new Error("Expected to find id: #{id}")
      @docs = clone(@docs)
      doc = @docs[fromIndex]
      @docs.splice(fromIndex, 1)
      if before is null
        @docs.push(doc)
        @updateMoved(clone(doc), fromIndex, @docs.length-1, before)
      else
        toIndex = @indexOf(before)
        if toIndex < 0 then throw new Error("Expected to find before _id: #{before}")
        @docs.splice(toIndex, 0, doc)
        @updateMoved(clone(doc), fromIndex, toIndex, before)
      unless noUpdate
        @dep.changed()


    changed: (id, fields, noUpdate=false) ->
      @docs = clone(@docs)
      i = @indexOf(id)
      if i < 0 then throw new Error("Expected to find id: #{id}")
      oldDoc = @docs[i]
      newDoc = changeDoc(oldDoc, fields)
      @updateChanged(newDoc, oldDoc, fields, i)
      unless noUpdate
        @dep.changed()


    removed: (id, noUpdate=false) ->
      i = @indexOf(id)
      if i < 0 then throw new Error("Expected to find id")
      delete @docIds[id]
      [oldDoc] = @docs.splice(i, 1)
      @updateRemoved(oldDoc, i)
      unless noUpdate
        @dep.changed()

    reset: ->
      # clear all observers
      for doc in @docs
        for key, observer of @changeObservers
          observer.removed(doc._id)
        for key, observer of @observers
          observer.removedAt(doc, 0)
      @docs = []
      @docIds = {}
      @dep.changed()


    # addOrMoveBefore: (doc, before) ->
    #   id = doc._id
    #   fromIndex = @indexOf(id)
    #   if fromIndex < 0
    #     @addedBefore(doc, before)
    #   else
    #     @movedBefore(doc, before)
    
    
  

  # This function removes the salted position
  parsePositions = (saltedObj) ->
    unless saltedObj
      return undefined
    positions = {}
    for subId, value of saltedObj
      if value isnt undefined
        before = value.split('.')[1]
        if before is "null" then before = null
        positions[subId] = before
    return positions

  parseDDPMsg = (msg) ->
    id = parseId(msg.id)
    msg.fields = fields2Obj(msg.fields)
    positions = {}
    cleared = {}
    subObj = msg.fields[DB.name]
    if subObj
      for subId, value of subObj
        if value is undefined
          cleared[subId] = true
        else
          before = value.split('.')[1]
          if before is "null" then before = null
          positions[subId] = before
    fields = omit([DB.name], fields)
    return {id, fields, positions, cleared}

  # Get the DDP connection so we can register a store and listen to messages
  DB.connection = if Meteor.isClient then Meteor.connection else Meteor.server
  
  # I'm simply copying how MDG does it with Mongo.
  # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp-client/livedata_connection.js#L1343
  # This is poorly/un- documented...
  # This how we deal with DDP messages that update the data on the client.

  findDoc = (id) ->
    for subId, sub in DB.subscriptions
      if sub.docIds[id]
        return clone(sub.docs[sub.indexOf(id)])
    return undefined

  DB.connection.registerStore DB.name,
    beginUpdate: (batchSize, reset) ->
      # Missing some kind of optimization here.
      # if batchSize > 1 or reset
      #   # pauseObservers
      if reset
        DB.reset()

    update: (msg) ->
      debug("msg", msg)

      {id, fields, positions, cleared} = parseDDPMsg(msg)
      

      if msg.msg is 'added'
        for subId, before of positions
          DB.subscriptions[subId].addedBefore(id, fields, before)
        return

      # if it simply cleared a publication, this should come though
      # as a change. removed means totally removed.[]
      if msg.msg is 'removed'
        for key, sub of DB.subscriptions
          sub.removed(id)
        return

      if msg.msg is 'changed'
        # remove cleared subscriptions
        for subId, value of cleared
          DB.subscriptions[subId].removed(id)

        # if the document exists in a different subscription
        # then when we add to another subscription, it will simply
        # be a change.
        for subId, before of positions
          sub = DB.subscriptions[subId]
          if sub.docIds[id]
            sub.movedBefore(id, before)
          else
            doc = findDoc(id)
            sub.addedBefore(id, omit(['_id'], doc) before)

        if R.keys(fields).length > 0
          for subId, sub of DB.subscriptions
            if sub.docIds[id]
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


