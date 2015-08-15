# debug = console.log.bind(console, 'store')
debug = (->)

serialize = JSON.stringify.bind(JSON)
clone = (obj) ->
  try
    return JSON.parse(JSON.stringify(obj))
  catch
    return obj

delay = (ms, func) -> Meteor.setTimeout(func, ms)
isNull = (x) -> x is null or x is undefined

# This cache survives hot reloads, caches any type of serializable data,
# supports watching for changes, and will delay before clearing the cache.
# call .get as many times as you want. .clear will set a timer unless .get
# is called before its times out.
createCache = (name, minutes=0) ->
  obj = {}
  obj.timers = {}
  obj.listeners = {}

  if Meteor.isClient and name
    # save the cache on live reloads
    obj.cache = Meteor._reload.migrationData(name+'-cache') or {}
    Meteor._reload.onMigrate name+'-cache', ->
      # clear anything that is pending to be cleared on live-reloads
      for key, {query, onDelete} of obj.timers
        obj.delete(query)
        onDelete?()
      [true, obj.cache]
  else
    obj.cache = {}

  obj.get = (query) ->
    key = serialize(query)
    Meteor.clearTimeout(obj.timers[key]?.timerId)
    delete obj.timers[key]
    return obj._get(query)

  # _get will not clear timeouts.
  obj._get = (query) ->
    key = serialize(query)
    return clone(obj.cache[key])

  obj.set = (query, value) ->
    key = serialize(query)
    data = clone(value)
    obj.cache[key] = data
    for id, func of (obj.listeners[key] or {})
      func(data)

  # listeners are not stopped on clear, only on delete.
  obj.watch = (query, func) ->
    key = serialize(query)
    unless obj.listeners[key]
      obj.listeners[key] = {}
    id = Random.hexString(10)
    obj.listeners[key][id] = func
    return {stop: -> delete obj.listeners[key]?[id]}

  obj.clear = (query, onDelete) ->
    key = serialize(query)
    obj.timers[key] =
      query: query
      onDelete: onDelete
      timerId: delay 1000*60*minutes, ->
        obj.delete(query)
        onDelete?()

  obj.delete = (query) ->
    key = serialize(query)
    Meteor.clearTimeout(obj.timers[key])
    delete obj.timers[key]
    delete obj.listeners[key]
    delete obj.cache[key]

  return obj

# a cache for counting .gets and .clears to make sure we dont clear a store when
# one views clears with while something else is still viewing it.
creactCounts = ->
  counts = createCache()
  counts.inc = (query) ->
    count = (counts.get(query) or 0) + 1
    counts.set(query, count)
    return count
  counts.dec = (query) ->
    count = counts.get(query) - 1
    counts.set(query, count)
    return count
  return counts

# {data, fetch, clear} = store.get(query)
@createRESTStore = (name, {minutes}, fetcher) ->
  store = {}
  store.cache = createCache(name, minutes)
  store.counts = creactCounts()

  respond = (query, data) ->
    data: data
    clear: -> store.clear(query)
    fetch: (callback) -> store.fetch(query, callback)
    watch: (listener) -> store.cache.watch query, (newData) -> listener(respond(query, newData))

  store.get = (query) ->
    store.counts.inc(query)
    respond(query, store.cache.get(query))

  store.fetch = (query, callback) ->
    fetcher query, (data) ->
      store.cache.set(query, data)
      callback?(respond(query, data))

  store.clear = (query) ->
    count = store.counts.dec(query)
    if count is 0
      store.counts.delete(query)
      store.cache.clear(query)

  return store

@createRESTListStore = (name, {limit, minutes}, fetcher) ->
  store = {}
  store.limit = limit
  store.cache = createCache(name, minutes)
  store.paging = createCache(name+'-paging')
  store.counts = creactCounts()

  respond = (query, data) ->
    {limit, offset} = store.paging.get(query) or {limit:store.limit, offset:0}
    fetch = (callback) -> store.fetch(query, callback)
    if data
      if data.length < limit + offset
        fetch = null
      else
        offset += limit
        store.paging.set(query, {limit, offset})

    return {
      data: data
      clear: -> store.clear(query)
      fetch: fetch
      watch: (listener) -> store.cache.watch query, (newData) -> listener(respond(query, newData))
    }

  store.get = (query) ->
    store.counts.inc(query)
    respond(query, store.cache.get(query))

  store.fetch = (query, callback) ->
    # need to get data to append, but only store.get should clear timeouts so
    # we're using _get just to be save
    data = store.cache._get(query)
    {limit, offset} = store.paging.get(query) or {limit:store.limit, offset:0}
    fetcher query, {limit, offset}, (result) ->
      data = (data or []).concat(result or [])
      store.cache.set(query, data)
      callback?(respond(query, data))

  store.clear = (query) ->
    # only clear if theres no one else watching!
    count = store.counts.dec(query)
    if count is 0
      store.counts.delete(query)
      store.cache.clear query, ->
        store.paging.delete(query)

  return store

@createDDPStore = (name, {ordered, cursor, minutes}, fetcher) ->
  store = {}

  if Meteor.isServer
    publish(name, {ordered, cursor}, fetcher)
    store.update = (query) -> refreshPub(name, query)
    return store

  if Meteor.isClient
    store.cache = createCache(name, minutes)
    store.subs = createCache()
    store.counts = creactCounts()

    respond = (query, data) ->
      data: data
      clear: -> store.clear(query)
      fetch: if data then null else (callback) -> store.fetch(query, callback)
      watch: (listener) -> store.cache.watch query, (newData) -> listener(respond(query, newData))

    store.get = (query) ->
      store.counts.inc(query)
      respond(query, store.cache.get(query))

    store.fetch = (query, callback) ->
      subscribe name, query, {}, (sub) ->
        # stop the old subscription
        store.subs.get(query)?()
        # set the new subscription
        store.subs.set(query, sub.stop)
        store.cache.set(query, sub.data or [])
        sub.onChange (data) ->
          store.cache.set(query, data)
        callback?(respond(query, sub.data))

    # latency compensation
    store.update = (query, transform) ->
      if transform
        # latency compensation can happen when a cached subscroption is waiting
        # to be cleared, so we'll want to make sure no to call .get
        data = store.cache._get(query)
        unless isNull(data)
          store.cache.set(query, transform(data))

    store.clear = (query) ->
      count = store.counts.dec(query)
      if count is 0
        store.counts.delete(query)
        store.cache.clear query, ->
          # stop subscription
          store.subs.get(query)?()
          store.subs.delete(query)

    return store

@createDDPListStore = (name, {ordered, cursor, minutes, limit}, fetcher) ->
  store = {}
  store.limit = limit

  if Meteor.isServer
    publish(name, {ordered, cursor}, fetcher)
    store.update = (query) -> refreshPub(name, query)
    return store

  if Meteor.isClient
    store.cache = createCache(name, minutes)
    store.subs = createCache()
    store.paging = createCache(name+'-paging')
    store.counts = creactCounts()

    respond = (query, data) ->
      {limit, offset} = store.paging.get(query) or {limit:store.limit, offset:0}
      fetch = (callback) -> store.fetch(query, callback)
      if data
        if data.length < limit + offset
          fetch = null
        else
          offset += limit
          store.paging.set(query, {limit, offset})

      return {
        data: data
        clear: -> store.clear(query)
        fetch: fetch
        watch: (listener) -> store.cache.watch query, (newData) -> listener(respond(query, newData))
      }

    store.get = (query) ->
      store.counts.inc(query)
      respond(query, store.cache.get(query))

    store.fetch = (query, callback) ->
      {limit, offset} = store.paging.get(query) or {limit:store.limit, offset:0}
      subscribe name, query, {limit, offset}, (sub) ->
        # stop the old subscription
        store.subs.get(query)?()
        # set the new subscription
        store.subs.set(query, sub.stop)
        store.cache.set(query, sub.data or [])
        sub.onChange (data) ->
          store.cache.set(query, data)
        callback?(respond(query, sub.data))

    # latency compensation
    store.update = (query, transform) ->
      if transform
        data = store.cache._get(query)
        unless isNull(data)
          store.cache.set(query, transform(data))

    store.clear = (query) ->
      count = store.counts.dec(query)
      if count is 0
        store.counts.delete(query)
        store.cache.clear query, ->
          # stop subscription
          store.subs.get(query)?()
          store.subs.delete(query)
        store.paging.delete(query)

    return store
