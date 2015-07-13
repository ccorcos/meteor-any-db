# for debug statements, switch the commented lines below
# debug = console.log.bind(console)
debug = (->)

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
  append
  concat
  pipe
} = R

# cache the result fo a function
remember = (f) ->
  result = null
  ->
    unless result
      result = f.apply(null, arguments)
    return result

# A simple counter that doesn't overflow.
counter = () ->
  i = 0
  ->
    i += 1
    i %= 100000000000
    return i

# rather than add lodash as a dependency
isPlainObject = (x) ->
  Object.prototype.toString.apply(x) is "[object Object]"

isNumber = (x) ->
  Object.prototype.toString.apply(x) is "[object Number]"

# an immutable version of "extend"
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
# This function simply removes those fields from and object.
deleteUndefined = (doc) ->
  obj = clone(doc)
  for k,v of obj
    if isPlainObject(v)
      obj[k] = deleteUndefined(v)
    else if v is undefined
      delete obj[k]
  return obj

# Given a document and some change fields, this will update the doc
# by merging them and removing the undefined fields
changeDoc = (doc, fields) ->
  deleteUndefined(mergeDeep(doc, fields))

# Its not particularly clear in the DDP spec if the fields object contains nested EJSON objects.
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#messages-2
# All I know is that they pass it directly into `$set` which, for nested objects, requires '.' separated strings.
# https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L179
# This function simply translates an object of "fields" with '.' separated keys for nested
# fields and translates that into a nested object.
# And it appears DDP doesnt do very well with nested key-values.
# https://forums.meteor.com/t/how-to-publish-nested-fields-that-arent-arrays/6007
# https://github.com/meteor/meteor/issues/4615
# So we will wrap objects into fields in the publication and unwrap back into
# objects in the subscriptions.

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
# documents. They use the `mongo-id` package but I get an error when I use it, so I copied it
# and it appears to be working just fine.
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
@DB = DB = {}
DB.name = 'ANY_DB'
# generate new document ids
DB.newId = -> Random.hexString(24)

# Publishing stuff on the server
if Meteor.isServer

  # Every position-related change has a special nested key-value that is
  # decoded on the client. The key for the positions is `DB.name` which is
  # an object that maps subscriptionIds to `before` positions. However, 
  # positions are stateful and merge-box isnt. For example, suppose we move
  # document a to the end, then document b to the end, then document a to the
  # end again, like this: a-null, b-null, a-null. Because merge-box isnt meant
  # to handle positions, it thinks a-null is repetitive and won't sent it to the
  # client. Thus we add some salt to it (a term used for "salting" password hashes).
  # The salt is simply a counter (that wont overflow). This ensures a new key-value
  # for every position. On the client, we simply parse out the salt and ignore it
  # using the `parsePositions` function.
  salter = counter()
  # Sets the position of the doc within the fields object and returns a new fields 
  # object. We have to salt the position value so merge-box doesnt kill the message 
  # as a repeat value.
  addPosition = R.curry (subId, before, fields) ->
    salt = salter()
    R.assocPath([DB.name, subId], "#{salt}.#{before}", fields)

  # DDP doesnt support ordered document collections yet
  # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#procedure-2
  # so we don't have addedBefore. We could be doing some advanced 
  # sorting in Neo4j that we couldnt do on the client.
  # Thus we'll add a key, DB.name to all position-based callbacks as a shim.
  # The key will have the subId and the salted position separated by a dot.
  # When you return a Mongo.Cursor from Meteor.publish, it calls this function:
  # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L302
  # So this function returns an observer that publishes ordered data to subscribers.
  createObserver = (pub, subId) ->
    addedBefore: (id, fields, before) ->
      fields = R.pipe(
        addPosition(subId, before)
        obj2Fields
      )(fields or {})
      pub.added(DB.name, id, fields)
      debug "added", subId, id, fields
    movedBefore: (id, before) ->
      fields = addPosition(subId, before, {})
      pub.changed(DB.name, id, fields)
      debug "moved", subId, id, fields
    changed: (id, fields) ->
      pub.changed(DB.name, id, fields)
      debug "changed", subId, id, fields
    removed: (id) ->
      pub.removed(DB.name, id)
      debug "removed", subId, id

  # Key-values of {subId:pollAndDiff}.
  # pollAndDiff is a function that triggers a "refresh"
  # of the publication.
  DB.triggers = {}

  # Registers a trigger for the subId
  registerTrigger = (pub, subId, pollAndDiff) ->
    DB.triggers[subId] = pollAndDiff
    pub.onStop -> delete DB.triggers[subId]

  # A function for triggering subscriptions
  DB.trigger = (subId) ->
    DB.triggers[subId]?()

  # Key-values of {dependencyKey:{subId: pollAndDiff}}
  # dependencyKeys are specified by publications and add their
  # pollAndDiff functions to the the appriate dependencyKey object. When you
  # trigger a dependency as changed, every function in the object
  # for that dependency will rerun. 
  # TODO: In the future, it wouldn't be a bad idea to use Tracker to leverage
  # the flush cycle so we dont rerun the same dependency multiple times
  # right after each other.
  DB.dependencies = {}

  # Registers a pollAndDiff function of a subId to an each
  # of the dependency `keys`.
  registerDeps = (pub, keys=[], subId, pollAndDiff) ->
    for key in keys
      unless DB.dependencies[key]
        DB.dependencies[key] = {}
      DB.dependencies[key][subId] = pollAndDiff
      pub.onStop -> delete DB.dependencies[key][subId]

  # Rerun all the pollAndDiff functions that depend on a key.
  DB.triggerDeps = (key) ->
    deps = DB.dependencies[key]
    if deps
      for subId, func of deps
        func()

  # Meteor does poll-and-diff does internally
  # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/polling_observe_driver.js#L124
  # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/polling_observe_driver.js#L176
  # start a poll-and-diff publication
  startPollAndDiff = (pub, pollAndDiff, ms) ->
    intervalId = Meteor.setInterval(pollAndDiff, ms)
    pub.onStop -> Meteor.clearInterval(intervalId)

  DB.pollAndDiffPublish = (name, ms, query, depends) ->
    # name:    name of the publication, so you can do DB.subscribe(name, args...)
    # ms:      millisecond interval to poll-and-diff.
    #          if ms <= 0 then we resort to triggered publishing
    # query:   a function called with args from DB.subscribe that returns a 
    #          collection of documents that must contain an `_id` field!
    # depends: a funciton that returns an array of dependency keys

    Meteor.publish name, (args) ->
      pub = this
      # grab the subscription Id
      subId = pub._subscriptionId
      # the current set of documents in this publication
      docs = []
      # the observer with the position shim
      observer = createObserver(pub, subId)
      # pass the arguments to the query function
      # returning a collection of documents
      poll = () -> query.apply(pub, args)
      # MDG did all the hard work of efficiently diff'ing two collections :)
      # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/diff-sequence/diff.js#L7
      pollAndDiff = ->
        newDocs = poll()
        DiffSequence.diffQueryChanges(true, docs, newDocs, observer)
        docs = newDocs
      # Get the initial documents.
      pollAndDiff()
      # Tell the client that the subscription is ready
      pub.ready()
      # Set up a trigger for this subscription
      registerTrigger(pub, subId, pollAndDiff)
      if depends
        # Set up the depencencies if its provided
        deps = depends.apply({}, args)
        registerDeps(pub, deps, subId, pollAndDiff)
      if ms > 0
        # Start an interval for poll and diff
        startPollAndDiff(pub, pollAndDiff, ms)
  

  # If you implement Curcor.observeChanges, then you can publish
  # with a cursor.
  DB.publishCursor = (name, getCursor) ->
    Meteor.publish name, (args) ->
      pub = this
      subId = pub._subscriptionId
      cursor = getCursor.apply(pub, args)
      observer = createObserver(pub, subId)
      handle = cursor.observeChanges(observer)
      pub.ready()
      pub.onStop ->
        handle.stop()

  # Determine what publication to start based on the
  # options passed in.
  DB.publish = ({name, query, depends, ms, cursor}) ->
    if cursor
      DB.publishCursor(name, cursor)
    else
      DB.pollAndDiffPublish(name, ms, query, depends)
      

# A client can trigger a refresh of their subscription with this
# Meteor.method. It seems like it could be a security vulnerability
# allowing the client access to other subscriptions, but in the 
# worst case scenario, a hacker may get lucky and trigger a 
# refresh on someone elses subscription. Thats no big deal.
Meteor.methods
  triggerSub: (subId) ->
    if Meteor.isServer
      DB.trigger(subId)

# TODO: We should be able to subscribe from server to server as well as 
# client to server but that will require some stuff with Fibers. 
# Right now, subscriptions just work on the client.
if Meteor.isClient

  # All subscriptions, keyed by the subId. 
  DB.subscriptions = {}

  # DBSubscriptionCurcor represents a single subscription on the client. It must 
  # be able to funciton like `Meteor.subcribe`, `Mongo.Collection`, and  `Mongo.Cursor`.
  # You call it with the arguments to the subscription. Then you can call start and 
  # stop on that subscription. You can observe and observeChanges with it. You can 
  # fetch() with it. And the nice thing is that it is also an observer, so you can
  # call addedBefore, movedBefore, changed, and removed to update it!

  # This just makes the API feel more functional
  DB.createSubscription = (name, args...) ->
    sub = new DBSubscriptionCursor(name, args)
    return sub

  # Reset all subscriptions
  DB.reset = ->
    debug "reset"
    for subId, sub of DB.subscriptions
      sub.reset()

  class DBSubscriptionCursor
    constructor: (@name, @args=[]) ->
      @docs = []
      @docIds = {}
      # this dependency allows .fetch() to be reactive
      @dep = new Tracker.Dependency()
      # we need a counter so observers have a key-value
      # so we can stop them easily.
      @observerCount = counter()
      @changeObservers = {}
      @observers = {}
      # undo functions for latenct compensation with {docId:undoFunc}
      @undos = {}

    # trigger the subscription to refresh
    trigger: ->
      if @subId
        Meteor.call('triggerSub', @subId)
      else
        throw new Error("You must start the subscription before you trigger it.")

    # Add an undo hook to undo any local, latency compensated changes
    addUndo: (id, undo) ->
      unless @undos[id]
        @undos[id] = []
      @undos[id].unshift(undo)

    # Handle undoing any latency compensated changes when DDP message comes
    # from the server with the specified id.
    handleUndo: (id) ->
      @undos[id]?.pop()?()

    # start the subscription.
    start: (onReady) ->
      subArgs = [@name, @args, onReady]
      @sub = sub = Meteor.subscribe.apply(Meteor, subArgs)
      @subId = subId = sub.subscriptionId
      DB.subscriptions[subId] = this
      # cleanup when running in an autorun
      if Tracker.currentComputation
        Tracker.onInvalidate =>
          @reset()

    # we must reset all observers when we stop the subscription
    # otherwise, when we start it again, we'll get repeat 
    # addedBefore messages all the observers.
    stop: ->
      @reset()

    # return a deep clone of the collection and also register
    # with the Tracker.Dependency for reactivity with Meteor.
    fetch: ->
      @dep.depend()
      return clone(@docs)

    observeChanges: (callbacks) ->
      # add all the initial docs
      for doc in clone(@docs)
        callbacks.addedBefore(doc._id, omit(["_id", doc]), null)
      i = @observerCount()
      @changeObservers[i] = callbacks
      return {stop: => delete @changeObservers[i]}

    observe: (callbacks) ->
      # add all the initial docs
      length = 0
      for doc in clone(@docs)
        callbacks.addedAt(doc, length, null)
        length++
      i = @observerCount()
      @observers[i] = callbacks
      return {stop: => delete @observers[i]}

    # Update all the observers appropriately based on incoming
    # DDP messages.
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

    # A helper function to find the index of a docId
    # within the collection.
    indexOf: (id) ->
      findIndex(propEq('_id', id), @docs)
  
    # Observer methods give a nice way to interact with the subscription
    # When DDP messages come in through `registerStore`, we call these 
    # methods to update the subscription.
    addedBefore: (id, fields, before) ->
      @handleUndo(id)
      doc = merge({_id: id}, fields)
      @docIds[id] = true
      if before is null
        @docs = append(doc, @docs)
        @updateAdded(clone(doc), @docs.length-1, before)
      else
        i = @indexOf(before)
        if i < 0 then throw new Error("Expected to find before _id, #{before}")
        @docs = clone(@docs)
        @docs.splice(i,0,doc)
        @updateAdded(clone(doc), i, before)
      @dep.changed()

    movedBefore: (id, before) ->
      @handleUndo(id)
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
      @dep.changed()

    changed: (id, fields) ->
      @handleUndo(id)
      @docs = clone(@docs)
      i = @indexOf(id)
      if i < 0 then throw new Error("Expected to find id: #{id}")
      oldDoc = @docs[i]
      newDoc = changeDoc(oldDoc, fields)
      @updateChanged(newDoc, oldDoc, fields, i)
      @dep.changed()

    removed: (id) ->
      @handleUndo(id)
      i = @indexOf(id)
      if i < 0 then throw new Error("Expected to find id")
      delete @docIds[id]
      [oldDoc] = @docs.splice(i, 1)
      @updateRemoved(oldDoc, i)
      @dep.changed()

    # reset the subscrption
    reset: ->
      if @sub
        @sub.stop()
        delete DB.subscriptions[@subId]
      # clear all observers
      for doc in @docs
        for key, observer of @changeObservers
          observer.removed(doc._id)
        for key, observer of @observers
          observer.removedAt(doc, 0)
      @docs = []
      @docIds = {}
      @undos = {}
      @dep.changed()

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

  # This function parses the id, the positions, any cleared subscriptions, 
  # and the fields. When you unsubscribe from a subscription, but the 
  # document still exists in another subscription, then the position
  # value of that document for that subscription will be be removed
  # by merge-box. Thus, setting the value to undefined according to the
  # documentation:
  # http://docs.meteor.com/#/full/observe_changes
  # > If a field was removed from the document then it will be present 
  # > in fields with a value of undefined.
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
    fields = omit([DB.name], msg.fields)
    return {id, fields, positions, cleared}

  # Get the DDP connection so we can register a store and listen to messages
  DB.connection = if Meteor.isClient then Meteor.connection else Meteor.server

  # Find a certain document by id, whereever it may be in any subscription.
  findDoc = (id) ->
    for subId, sub of DB.subscriptions
      if sub.docIds[id]
        return clone(sub.docs[sub.indexOf(id)])
    return undefined

  # This is undocumented so I'm simply copying how MDG does it with Mongo.
  # https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp-client/livedata_connection.js#L1343
  # We use `connection.registerStore` to register a data store on the client
  # for a certain name. This is the same name we use when we call `pub.added`.
  # Here, we can parse out DDP messages and handle them appropriately.

  DB.connection.registerStore DB.name,
    beginUpdate: (batchSize, reset) ->
      # We're missing some kind of optimization here that
      # MDG does with Mongo, but it doesnt seem to matter.
      # if batchSize > 1 or reset
      #   # pauseObservers
      if reset
        DB.reset()

    # Because DBSubsctiptionCursors are also observer, 
    # its easy to use those methods to update them.
    update: (msg) ->
      debug("msg", msg)
      {id, fields, positions, cleared} = parseDDPMsg(msg)
      
      if msg.msg is 'added'
        for subId, before of positions
          DB.subscriptions[subId].addedBefore(id, fields, before)
        return

      # this means entirely removed from the client. If we simply 
      # cleared a subscription, then it would be a change message
      # and that subscription position would be undefined.
      if msg.msg is 'removed'
        for key, sub of DB.subscriptions
          if sub.docIds[id]
            sub.removed(id)
        return

      if msg.msg is 'changed'
        # remove cleared subscriptions which come in as a subId
        # position set to undefined
        for subId, value of cleared
          debug "cleared", id, "from", subId
          sub = DB.subscriptions[subId]
          sub.removed(id)

        # If the document exists in a different subscription and
        # we start another subscription that has overlap, then 
        # merge-box will only send the change -- typically just
        # the position of the document in the other subscription.
        # Thus, we have to find the document in the other subscriptions
        # and add it to the new subscription.
        # 
        # This was previously implemented with a global set of documents
        # that were mutated and passed by reference to each subscription.
        # This is more computationally efficient but it is a nightmare to 
        # work with. I'd much rather settle for immutable data and code thats
        # easier to understand and reason about. This code is on the client
        # so efficiency isn't as important (there arent going to be thousands 
        # of documents on the client), and using some techniques like 
        # `remember` and `sub.docIds`, its pretty efficient.
        lookup = remember(findDoc)
        for subId, before of positions
          sub = DB.subscriptions[subId]
          # if the document exists, then this is a move.
          # otherwise, we interpret it as an add.
          if sub.docIds[id]
            sub.movedBefore(id, before)
          else
            doc = lookup(id)
            sub.addedBefore(id, omit(['_id'], doc), before)

        # the basic field changes
        if R.keys(fields).length > 0
          for subId, sub of DB.subscriptions
            if sub.docIds[id]
              sub.changed(id, fields)
        return

      throw new Error("I don't know how to deal with this message");

    endUpdate: ->
      # Again, another optimization that doesn't
      # seem to matter much. 
      # resumeObservers