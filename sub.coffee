{DB_KEY} = AnyDb # Spoofing a Mongo collection name to hack around DDP

debug = (->)
if Meteor.settings.public?.log?.sub
  debug = console.log.bind(console, 'sub')

# find the index of a document with a given id within a collection
findDocIdIndex = (id, docs) ->
  for i in [0...docs.length]
    if docs[i]._id is id
      return i
  return -1

# mutably remove fields that are set to undefined
deleteUndefined = (doc) ->
  for k,v of doc
    if U.isPlainObject(v)
      doc[k] = deleteUndefined(v)
    else if v is undefined
      delete doc[k]
  return

# update the document based on the fields
changeDoc = (doc, fields) ->
  deleteUndefined(U.extendDeep(doc, fields))
  return

# subs[subId] = subObject
AnyDb.subs = {}

AnyDb.subscribe = (name, query, onReady) ->
  sub = {name, query}   # name and query are useful here just for debugging
  sub.data = []         # subscriptions always return collections
  sub.dataIds = {}      # keep track of which id's belong to this subscription
  sub.ready = false     # don't fire onChange methods until the subscription is ready

  # onChange listeners
  sub.listeners = {}
  sub.onChange = (f) ->
    id = Random.hexString(10)
    sub.listeners[id] = f
    {stop: -> delete sub.listeners[id]}
  dispatchChange = ->
    if sub.ready
      debug('change', sub.subId, 'listeners', Object.keys(sub.listeners).length)
      for id, f of sub.listeners
        f(R.clone(sub.data))

  # The following observer methods will be called as DDP messages come in
  # via Meteor.connection.registerStore

  sub.addedBefore = (id, fields, before) ->
    doc = fields
    doc._id = id
    sub.dataIds[id] = true
    if before is null
      sub.data = sub.data.concat(doc)
    else
      i = findDocIdIndex(before, sub.data)
      if i < 0 then throw new Error("Expected to find before id, #{before}")
      sub.data = R.clone(sub.data)
      sub.data.splice(i,0,doc)
    dispatchChange()

  sub.movedBefore = (id, before) ->
    fromIndex = findDocIdIndex(id, sub.data)
    if fromIndex < 0 then throw new Error("Expected to find id: #{id}")
    sub.data = R.clone(sub.data)
    doc = sub.data[fromIndex]
    sub.data.splice(fromIndex, 1)
    if before is null
      sub.data.push(doc)
    else
      toIndex = findDocIdIndex(before, sub.data)
      if toIndex < 0 then throw new Error("Expected to find before _id: #{before}")
      sub.data.splice(toIndex, 0, doc)
    dispatchChange()

  sub.changed = (id, fields) ->
    sub.data = R.clone(sub.data)
    i = findDocIdIndex(id, sub.data)
    if i < 0 then throw new Error("Expected to find id: #{id}")
    changeDoc(sub.data[i], fields)
    dispatchChange()

  sub.removed = (id) ->
    i = findDocIdIndex(id, sub.data)
    if i < 0 then throw new Error("Expected to find id")
    [oldDoc] = sub.data.splice(i, 1)
    delete sub.dataIds[id]
    dispatchChange()

  lap = U.stopwatch()
  debug('start', name)
  # make sure reactive computations dont fuck this up, especially
  # on hot reloads.
  handle = Tracker.nonreactive ->
    Meteor.subscribe name, query,
      onReady: ->
        debug('ready', name, sub.subId, lap(), 's')
        sub.ready = true
        dispatchChange()
        onReady?(sub)
      onStop: (e) ->
        debug('stopped', name, sub.subId)
        if e then throw(e)

  sub.subId = handle.subscriptionId

  sub.stop = ->
    debug('stop', name, sub.subId)
    sub.listeners = {}
    handle.stop()
    sub.data = []
    sub.dataIds = {}
    # unregister the subscription
    delete AnyDb.subs[sub.subId]

  sub.reset = ->
    debug('reset', name, sub.subId)
    sub.data = []
    sub.dataIds = {}
    # dispatchChange()s

  # register the subscription
  AnyDb.subs[sub.subId] = sub
  return sub

# Find a certain document by id, where ever it may be in any subscription.
AnyDb.findDoc = (id) ->
  for subId, sub of AnyDb.subs
    if sub.dataIds[id]
      i = findDocIdIndex(id, sub.data)
      return R.clone(sub.data[i])
  return undefined

# unflatten DDP fields into a deep object
fields2Obj = (fields={}) ->
  fields = R.clone(fields)
  dest = {}
  for key,value of fields
    keys = key.split('.').reverse()
    if keys.length is 1
      dest[key] = value
    else
      obj = {}
      prevObj = obj
      while keys.length > 1
        tmp = {}
        prevObj[keys.pop()] = tmp
        prevObj = tmp
      prevObj[keys.pop()] = value
      U.extendDeep(dest, obj)
  return dest

# some weird stuff going on with DDP
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

# parse the subscription, position, cleared, fields, etc.
parseDDPMsg = (msg) ->
  id = parseId(msg.id)
  msg.fields = fields2Obj(msg.fields)
  positions = {}
  cleared = {}
  subObj = msg.fields[DB_KEY]
  if subObj
    for subId, value of subObj
      if value is undefined
        cleared[subId] = true
      else
        before = value.split('.')[1]
        if before is "null" then before = null
        positions[subId] = before
  fields = R.clone(msg.fields)
  delete fields[DB_KEY]
  return {id, fields, positions, cleared}

Meteor.connection.registerStore DB_KEY,
  beginUpdate: (batchSize, reset) ->
    if reset
      for subId, sub of AnyDb.subs
        sub.reset()

  update: (msg) ->
    {id, fields, positions, cleared} = parseDDPMsg(msg)

    if msg.msg is 'added'
      for subId, before of positions
        sub = AnyDb.subs[subId]
        sub.addedBefore(id, R.clone(fields), before)
      return

    if msg.msg is 'removed'
      for subId, sub of AnyDb.subs
        if sub.dataIds[id] then sub.removed(id)
      return

    if msg.msg is 'changed'
      # remove cleared subscriptions which come in as a subId
      # position set to undefined
      for subId, value of cleared
        sub = AnyDb.subs[subId]
        # the subscription cleans itself up when it stops so it may
        # not be found
        sub?.removed(id)

      lookup = R.memoize(AnyDb.findDoc)
      for subId, before of positions
        sub = AnyDb.subs[subId]
        # sub could be null apparently if you logout and back in really quickly
        if not sub then return
        if sub.dataIds[id]
          sub.movedBefore(id, before)
        else
          doc = lookup(id)
          sub.addedBefore(id, R.omit(['_id'], doc), before)

      # the basic field changes
      if Object.keys(fields).length > 0
        for subId, sub of AnyDb.subs
          if sub.dataIds[id] then sub.changed(id, R.clone(fields))
      return

    throw new Error("I don't know how to deal with this message");
