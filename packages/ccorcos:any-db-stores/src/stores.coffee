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
# simulate latency on the client
SIM_DELAY = Meteor.settings.public.simulated_delay_ms || 0
fdelay = (f) -> f
if SIM_DELAY > 0
  fdelay = (f) -> (args...) -> delay SIM_DELAY, -> f?.apply(null, args)

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



# {data, fetch, clear} = store.get(query)
@createRESTStore = (name, {minutes}, fetcher) ->
  store = {}
  store.cache = createCache(name, minutes)
  store.counts = createCache()

  response = (query, data) ->
    data: data
    clear: -> store.clear(query)
    fetch: (callback) -> store.fetch(query, callback)
    watch: (listener) -> store.cache.watch query, (newData) -> listener(reponse(query, newData))

  store.get = (query) ->
    count = (store.counts.get(query) or 0) + 1
    store.counts.set(query, count)
    response(query, store.cache.get(query))

  store.fetch = (query, callback) ->
    fetcher query, (data) ->
      store.cache.set(query, data)
      callback?(response(query, data))

  store.clear = (query) ->
    count = (store.counts.get(query) or 0) - 1
    store.counts.set(query, count)
    if count is 0
      store.counts.delete(query)
      store.cache.clear(query)

  return store

@createRESTListStore = (name, {limit, minutes}, fetcher) ->
  LIMIT = limit
  store = {}
  store.cache = createCache(name, minutes)
  store.paging = createCache(name+'-paging')

  store.fetch = (query, callback) ->
    data = store.cache.get(query)
    {limit, offset} = store.paging.get(query) or {limit:LIMIT, offset:0}
    if data and data.length >= limit + offset
      offset += limit
      store.paging.set(query, {limit, offset})
    debug('fetch...', name, query, limit+offset)
    fetcher query, {limit, offset}, (result) ->
      debug('     ...done', name, query, limit+offset)
      data = (data or []).concat(result or [])
      store.cache.set(query, data)
      fdelay(callback)?(store.get(query))

  store.get = (query) ->
    data = store.cache.get(query)
    {limit, offset} = store.paging.get(query) or {limit:LIMIT, offset:0}
    debug('get', name, query, limit+offset)
    fetch = (callback) -> store.fetch(query, callback)
    if data and data.length < limit + offset
      fetch = null

    return {
      data: data
      clear: -> store.clear(query)
      fetch: fetch
      watch: (listener) -> store.cache.watch query, fdelay -> listener(store.get(query))
    }

  store.clear = (query) ->
    debug('clear', name, query)
    store.cache.clear query, ->
      # onDelete
      debug('delete', name, query)
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

    store.get = (query) ->
      debug('get', name, query)
      data = store.cache.get(query)
      return {
        data: data
        clear: -> store.clear(query)
        fetch: if data then null else (callback) -> store.fetch(query, callback)
        watch: (listener) -> store.cache.watch query, fdelay -> listener(store.get(query))
      }

    store.fetch = (query, callback) ->
      debug('fetch...', name, query)
      data = store.cache.get(query)
      subscribe name, query, {}, (sub) ->
        debug('     ...done', name, query)
        store.subs.get(query)?()
        store.subs.set(query, sub.stop)
        store.cache.set(query, sub.data or [])
        sub.onChange (data) ->
          store.cache.set(query, data)
        fdelay(callback)?(store.get(query))

    # latency compensation
    store.update = (query, transform) ->
      debug('update', name, query)
      if transform
        data = store.cache.get(query)
        unless isNull(data)
          store.cache.set(query, transform(data))

    store.clear = (query) ->
      debug('clear', name, query)
      store.cache.clear query, ->
        # onDelete
        debug('delete', name, query)
        store.subs.get(query)?()
        store.subs.delete(query)

    return store

@createDDPListStore = (name, {ordered, cursor, minutes, limit}, fetcher) ->
  store = {}
  LIMIT = limit

  if Meteor.isServer
    publish(name, {ordered, cursor}, fetcher)
    store.update = (query) -> refreshPub(name, query)
    return store

  if Meteor.isClient
    store.cache = createCache(name, minutes)
    store.subs = createCache()
    store.paging = createCache(name+'-paging')

    store.get = (query) ->
      data = store.cache.get(query)
      {limit, offset} = store.paging.get(query) or {limit:LIMIT, offset:0}
      debug('get', name, query, limit+offset)

      fetch = (callback) -> store.fetch(query, callback)
      if data and data.length < limit + offset
        fetch = null

      return {
        data: data
        clear: -> store.clear(query)
        fetch: fetch
        watch: (listener) -> store.cache.watch query, fdelay -> listener(store.get(query))
      }

    store.fetch = (query, callback) ->
      data = store.cache.get(query)
      {limit, offset} = store.paging.get(query) or {limit:LIMIT, offset:0}

      if data and data.length >= limit + offset
        offset += limit
        store.paging.set(query, {limit, offset})

      debug('fetch...', name, query, limit+offset)
      subscribe name, query, {limit, offset}, (sub) ->
        debug('     ...done', name, query, limit+offset)
        store.subs.get(query)?()
        store.subs.set(query, sub.stop)
        store.cache.set(query, sub.data or [])
        sub.onChange (data) ->
          store.cache.set(query, data)
        fdelay(callback)?(store.get(query))

    # latency compensation
    store.update = (query, transform) ->
      debug('update', name, query)
      if transform
        data = store.cache.get(query)
        unless isNull(data)
          store.cache.set(query, transform(data))

    store.clear = (query) ->
      debug('clear', name, query)
      store.cache.clear query, ->
        debug('delete', name, query)
        store.subs.get(query)?()
        store.subs.delete(query)
        store.paging.delete(query)

    return store
