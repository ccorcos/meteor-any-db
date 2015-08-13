DB_KEY = "any-db" # Spoofing a Mongo collection name to hack around DDP

serialize = JSON.stringify.bind(JSON)
salter = Random.hexString.bind(Random, 10)
clone = (obj) -> JSON.parse(JSON.stringify(obj))

# mutably set a value of an object given an array of keys
set = (path, value, object) ->
  first = path[0]
  rest = path[1...]
  if rest.length is 0
    object[first] = value
  else
    unless object[first]
      object[first] = {}
    set(rest, value, object[first])

# mutably unset / delete a value of an object given an array of keys
unset = (path, object) ->
  first = path[0]
  rest = path[1...]
  if rest.length is 0
    delete object[first]
  else
    unset(rest, object[first])
    if Object.keys(object[first]).length is 0
      delete object[first]

# given an object of {id:value}, return an IdMap
docs2IdMap = (docs) ->
  map = new IdMap()
  for doc in docs
    map.set(doc._id, doc)
  return map

# find the index of a document with a given id within a collection
findDocIdIndex = (id, docs) ->
  for i in [0...docs.length]
    if docs[i]._id is id
      return i
  return -1

isArray = (x) ->
  Object.prototype.toString.apply(x) is '[object Array]'

isPlainObject = (x) ->
  Object.prototype.toString.apply(x) is '[object Object]'

# mutable deep extend
extendDeep = (dest, obj) ->
  for k,v of obj
    if isPlainObject(v)
      dest[k] = dest[k] or {}
      extendDeep(dest[k], v)
    else
      dest[k] = v
  return

# mutably remove fields that are set to undefined
deleteUndefined = (doc) ->
  for k,v of doc
    if isPlainObject(v)
      doc[k] = deleteUndefined(v)
    else if v is undefined
      delete doc[k]
  return

# update the document based on the fields
changeDoc = (doc, fields) ->
  deleteUndefined(extendDeep(doc, fields))
  return

# cache the result fo a function
memoize = (f) ->
  result = null
  return () ->
    unless result
      result = f.apply(null, arguments)
    return result

# unflatten DDP fields into a deep object
fields2Obj = (fields={}) ->
  fields = clone(fields)
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
      extendDeep(dest, obj)
  return dest

# flatten a deep object into fields separated with '.'
obj2Fields = (obj={}) ->
  dest = {}
  for key,value of obj
    if isPlainObject(value)
      deeperFields = obj2Fields(value)
      for k,v of deeperFields
        dest["#{key}.#{k}"] = v
    else
      dest[key] = clone(value)
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
      else if value is 'true'
        positions[subId] = 'true'
      else
        before = value.split('.')[1]
        if before is "null" then before = null
        positions[subId] = before
  fields = clone(msg.fields)
  delete fields[DB_KEY]
  return {id, fields, positions, cleared}


# publishing from the server
if Meteor.isServer
  # publish with the subscription id.
  createUnorderedObserver = (pub, subId) ->
    added: (id, fields={}) ->
      set([DB_KEY, subId], 'true', fields)
      pub.added(DB_KEY, id, obj2Fields(fields))
    changed: (id, fields) ->
      pub.changed(DB_KEY, id, fields)
    removed: (id) ->
      pub.removed(DB_KEY, id)

  # publish with the subscriptionId and the position
  createOrderedObserver = (pub, subId) ->
    addedBefore: (id, fields={}, before) ->
      set([DB_KEY, subId], "#{salter()}.#{before}", fields)
      pub.added(DB_KEY, id, obj2Fields(fields))
    movedBefore: (id, before) ->
      fields = {}
      set([DB_KEY, subId], "#{salter()}.#{before}", fields)
      pub.changed(DB_KEY, id, obj2Fields(fields))
    changed: (id, fields) ->
      pub.changed(DB_KEY, id, fields)
    removed: (id) ->
      pub.removed(DB_KEY, id)

  publishUnorderedCursor = (name, getCursor) ->
    Meteor.publish name, (query, options) ->
      pub = this
      try
        subId = pub._subscriptionId
        observer = createUnorderedObserver(pub, subId)
        handle = getCursor.call(pub, query, options).observeChanges(observer)
        pub.ready()
        pub.onStop -> handle.stop()
      catch e
        throw e
        pub.error(new Meteor.Error(33, 'Publication error'))

  publishOrderedCursor = (name, getCursor) ->
    Meteor.publish name, (query, options) ->
      pub = this
      try
        subId = pub._subscriptionId
        observer = createOrderedObserver(pub, subId)
        handle = getCursor.call(pub, query, options).observeChanges(observer)
        pub.ready()
        pub.onStop -> handle.stop()
      catch e
        throw e
        pub.error(new Meteor.Error(33, 'Publication error'))

  # XXX We should be caching subscriptions together here somehow.

  # pubs[pubKey][pubId][subId] = refresh
  # pubKey doesnt serialize the options so you can specify a publication to
  # refresh regardless of the paging. pubId includes the options which will
  # eventually allow us to cache subscriptions hopefully. SubId is the specific
  # id of that sub from the client.
  pubs = {}

  # refresh all pubs of a given name and query. Its important that if the
  # current userId is relevant, then it needs to be included in the query
  # and checked against this.userId.
  @refreshPub = (name, query) ->
    pubKey = serialize([name, query])
    for pubId, subs of pubs[pubKey]
      for subId, refresh of subs
        refresh()

  publishUnorderedDocuments = (name, fetcher) ->
    Meteor.publish name, (query, options) ->
      pub = this
      try
        pubKey = serialize([name, query])
        pubId = serialize([name, query, options])
        subId = pub._subscriptionId
        docs = new IdMap()
        fetch = -> docs2IdMap(fetcher.call(pub, query, options))
        observer = createUnorderedObserver(pub, subId)
        refresh = ->
          newDocs = fetch()
          DiffSequence.diffQueryChanges(false, docs, newDocs, observer)
          docs = newDocs
        refresh()
        pub.ready()
        set([pubKey, pubId, subId], refresh, pubs)
        pub.onStop -> unset([pubKey, pubId, subId], pubs)
      catch e
        throw e
        pub.error(new Meteor.Error(33, 'Publication error'))

  publishOrderedDocuments = (name, fetcher) ->
    Meteor.publish name, (query, options) ->
      try
        pub = this
        pubKey = serialize([name, query])
        pubId = serialize([name, query, options])
        subId = pub._subscriptionId
        docs = []
        fetch = -> fetcher.call(pub, query, options)
        observer = createOrderedObserver(pub, subId)
        refresh = ->
          newDocs = fetch()
          DiffSequence.diffQueryChanges(true, docs, newDocs, observer)
          docs = newDocs
        refresh()
        pub.ready()
        set([pubKey, pubId, subId], refresh, pubs)
        pub.onStop -> unset([pubKey, pubId, subId], pubs)
      catch e
        throw e
        pub.error(new Meteor.Error(33, 'Publication error'))

  @publish = (name, {ordered, cursor}, fetcher) ->
    if ordered and cursor
      publishOrderedCursor(name, fetcher)
    else if not ordered and cursor
      publishUnorderedCursor(name, fetcher)
    else if ordered and not cursor
      publishOrderedDocuments(name, fetcher)
    else if not ordered and not cursor
      publishUnorderedDocuments(name, fetcher)
    else
      throw new Meteor.Error(666, 'this cant happen')

if Meteor.isClient

  subs = {}

  # Find a certain document by id, whereever it may be in any subscription.
  findDoc = (id) ->
    for subId, sub of subs
      if sub.dataIds[id]
        if isArray(sub.data)
          i = findDocIdIndex(id, sub.data)
          return clone(sub.data[i])
        else
          return clone(sub.data[id])
    return undefined

  @subscribe = (name, query, options, callback) ->
    sub = {}
    sub.data = []
    sub.dataIds = {}
    sub.ready = false

    # onChange listeners
    sub.listeners = {}
    sub.onChange = (f) ->
      id = salter()
      sub.listeners[id] = f
      {stop: -> delete sub.listeners[id]}
    dispatchChange = ->
      if sub.ready
        for id, f of sub.listeners
          f(clone(sub.data))

    # unordered publications
    sub.added = (id, fields) ->
      doc = fields
      doc._id = id
      sub.data = sub.data.concat(doc)
      sub.dataIds[id] = true
      dispatchChange()

    # ordered publications
    sub.addedBefore = (id, fields, before) ->
      doc = fields
      doc._id = id
      sub.dataIds[id] = true
      if before is null
        sub.data = sub.data.concat(doc)
      else
        i = findDocIdIndex(before, sub.data)
        if i < 0 then throw new Error("Expected to find before id, #{before}")
        sub.data = clone(sub.data)
        sub.data.splice(i,0,doc)
      dispatchChange()

    # ordered publications
    sub.movedBefore = (id, before) ->
      fromIndex = findDocIdIndex(id, sub.data)
      if fromIndex < 0 then throw new Error("Expected to find id: #{id}")
      sub.data = clone(sub.data)
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
      sub.data = clone(sub.data)
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

    handle = Meteor.subscribe name, query, options,
      onReady: ->
        sub.ready = true
        if sub.data then dispatchChange()
        callback?(sub)
      onStop: (e) ->
        if e then throw(e)

    sub.subId = subId = handle.subscriptionId

    sub.stop = ->
      sub.listeners = {}
      handle.stop()
      sub.data = []
      sub.dataIds = {}
      unset([subId], subs)

    sub.reset = ->
      sub.data = []
      sub.dataIds = {}

    set([subId], sub, subs)
    return sub

  resetSubs = ->
    for subId, sub of subs
      sub.reset()

  Meteor.connection.registerStore DB_KEY,
    beginUpdate: (batchSize, reset) ->
      if reset then resetSubs()

    update: (msg) ->
      {id, fields, positions, cleared} = parseDDPMsg(msg)

      if msg.msg is 'added'
        for subId, before of positions
          sub = subs[subId]
          if before is 'true'
            sub.added(id, fields)
          else
            sub.addedBefore(id, fields, before)
        return

      if msg.msg is 'removed'
        for subId, sub of subs
          if sub.dataIds[id] then sub.removed(id)
        return

      if msg.msg is 'changed'
        # remove cleared subscriptions which come in as a subId
        # position set to undefined
        for subId, value of cleared
          sub = subs[subId]
          # the subscription cleans itself up when it stops so it may
          # not be found
          sub?.removed(id)

        lookup = memoize(findDoc)
        for subId, before of positions
          sub = subs[subId]
          if before isnt 'true' and sub.dataIds[id]
            sub.movedBefore(id, before)
          else
            doc = lookup(id)
            fields = clone(doc)
            delete fields['_id']
            if before is 'true'
              sub.added(id, fields)
            else
              sub.addedBefore(id, fields, before)

        # the basic field changes
        if Object.keys(fields).length > 0
          for subId, sub of subs
            if sub.dataIds[id] then sub.changed(id, fields)
        return

      throw new Error("I don't know how to deal with this message");
