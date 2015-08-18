# debug = console.log.bind(console, 'store')
debug = (->)

serialize = JSON.stringify.bind(JSON)
deserialize = JSON.parse.bind(JSON)
delay = (ms, func) -> Meteor.setTimeout(func, ms)

isArray = (x) ->
  Object.prototype.toString.apply(x) is '[object Array]'

isPlainObject = (x) ->
  Object.prototype.toString.apply(x) is '[object Object]'

isFunction = (x) ->
  Object.prototype.toString.apply(x) is '[object Function]'

pick = (keys, obj) ->
  x = {}
  for key in keys
    x[key] = obj[key]
  return x

# clone arrays or objects
# functions and numbers are left alone
# strings aren't typically mutated, so they're left alone as well
clone = (x) ->
  if isPlainObject(x)
    cloned = {}
    for k,v of x
      cloned[k] = clone(v)
    return cloned
  else if isArray(x)
    cloned = []
    for v in x
      cloned.push(clone(v))
    return cloned
  else
    return x

mapObj = (obj, func) ->
  newObj = {}
  for k,v of obj
    newObj[k] = func(k,v,obj)
  return newObj

# createCache
# - serializes key data
# - watch for changes to key
# - delay on clearing a key
# - .get will stop any timers
# - .clear will start a timer
# - .delete will clear immediately
# - survives hot code pushes given a unique name
@createCache = createCache = (name, minutes=0) ->
  obj = {minutes}
  obj.timers = {}      # obj.timers[serialize(query)] = {timerId, delete}
  obj.listeners = {}   # obj.listeners[serialize(query)] = {id: func(data)}

  if Meteor.isClient and name
    # save the cache on live reloads
    obj.cache = Meteor._reload.migrationData(name+'-cache') or {}
    Meteor._reload.onMigrate name+'-cache', ->
      # clear anything that is pending to be cleared on live-reloads
      # because the timers will not survive. the timers could just be
      # restarted but that seems like overkill
      mapObj obj.timers, (key, obj) -> obj.delete()
      [true, obj.cache]
  else
    # you can use this cache on the server if you want too
    obj.cache = {}

  # ._get will not clear timeouts
  obj._get = (query) ->
    key = serialize(query)
    return clone(obj.cache[key])

  # filter for queries that match a condition
  obj._match = (cond) ->
    keys = Object.keys(obj.cache)
      .map(deserialize)
      .filter(cond)
      .map(serialize)
    pick(keys, obj.cache)

  # .get will clear any timeouts before returning data
  obj.get = (query) ->
    key = serialize(query)
    Meteor.clearTimeout(obj.timers[key]?.timerId)
    delete obj.timers[key]
    return obj._get(query)

  # set the data in the cache and call any listeners
  obj.set = (query, value) ->
    key = serialize(query)
    data = clone(value)
    obj.cache[key] = data
    mapObj obj.listeners[key], (id, func) -> func(data)

  # listeners can watch for changes with a callback.
  # listeners are not stopped on clear, only on delete.
  obj.watch = (query, func) ->
    key = serialize(query)
    id = Random.hexString(10)
    unless obj.listeners[key]
      obj.listeners[key] = {}
    obj.listeners[key][id] = func
    return {stop: -> delete obj.listeners[key]?[id]}

  # set a timeout to delete the item from the cache
  obj.clear = (query, onDelete) ->
    key = serialize(query)
    obj.timers[key] =
      delete: ->
        obj.delete(query)
        onDelete?()
      timerId: delay 1000*60*minutes, -> obj.delete(query)

  obj.delete = (query) ->
    key = serialize(query)
    Meteor.clearTimeout(obj.timers[key])
    delete obj.timers[key]
    delete obj.listeners[key]
    delete obj.cache[key]

  return obj

# {data, fetch, clear, watch} = store.get(query)
# this store will cache data for you and provide a nice interface for
# fetching data, watching for changes, and caching it when you're done with it.
# you must call clear for every time you call get in order to clean up.
@createRESTStore = (name, {minutes}, fetcher) ->
  store = {}
  store.cache = createCache(name, minutes)

  # we have to keep track of how many times we've called get and clear
  # because we dont want to call clear if this data is being used in two
  # places and one place is done with it.
  store.counts = createCache()
  store.inc = (query) ->
    count = (store.counts.get(query) or 0) + 1
    store.counts.set(query, count)
    return count
  store.dec = (query) ->
    count = store.counts.get(query) - 1
    store.counts.set(query, count)
    return count

  # respond to get, fetch, and watch with the same interface
  store.respond = (query, data) ->
    data: data
    clear: -> store.clear(query)
    fetch: (callback) -> store.fetch(query, callback)
    watch: (listener) -> store.watch(query, listener)

  store.get = (query) ->
    store.inc(query)
    store.respond(query, store.cache.get(query))

  store.fetch = (query, callback) ->
    fetcher query, (data) ->
      store.cache.set(query, data)
      callback?(store.respond(query, data))

  store.watch = (query, listener) ->
    store.cache.watch query, (newData) ->
      listener(store.respond(query, newData))

  store.clear = (query, onDelete) ->
    count = store.dec(query)
    unless count > 0
      store.counts.delete(query) # clean up immediately
      store.cache.clear(query, onDelete)
      onDelete?()

  return store


@createRESTListStore = (name, {limit, minutes}, fetcher) ->
  store = createRESTStore(name, {minutes}, fetcher)
  store.limit = limit
  store.paging = createCache(name+'-paging')

  store.respond = (query, data) ->
    {limit, offset} = store.paging.get(query) or {limit:store.limit, offset:0}
    fetch = (callback) -> store.fetch(query, callback)
    if data
      if data.length < limit + offset
        fetch = undefined
      else
        offset += limit
        store.paging.set(query, {limit, offset})

    return {
      data: data
      clear: -> store.clear(query)
      fetch: fetch
      watch: (listener) -> store.watch(query, listener)
    }

  store.fetch = (query, callback) ->
    # need to get data to append, but store.get clears timeouts so we're
    # using store._get just to be sace
    data = store.cache._get(query)
    {limit, offset} = store.paging.get(query) or {limit:store.limit, offset:0}
    fetcher {query, limit, offset}, (result) ->
      data = (data or []).concat(result or [])
      store.cache.set(query, data)
      callback?(store.respond(query, data))

  # clean up paging!
  clear = store.clear
  store.clear = (query, onDelete) ->
    clear query, ->
      store.paging.delete(query)
      onDelete?()

  return store


@createDDPStore = (name, {ordered, cursor, minutes}, fetcher) ->
  store = createRESTStore(name, {minutes}, fetcher)

  if Meteor.isServer
    publish(name, {ordered, cursor}, fetcher)
    store.update = (cond) -> refreshPub(name, cond)
    return store

  if Meteor.isClient
    store.subs = createCache()

    store.fetch = (query, callback) ->
      subscribe name, query, (sub) ->
        store.subs.get(query)?()           # stop the old subscription in case we fetch twice
        store.subs.set(query, sub.stop)    # set the new subscription
        store.cache.set(query, sub.data or [])
        sub.onChange (data) -> store.cache.set(query, data)
        callback?(store.respond(query, sub.data))

    # latency compensation
    store.update = (cond, transform) ->
      if transform
        # latency compensation can happen when a cached subscription is waiting
        # to be cleared, so we'll want to make sure not to call .get
        if isFunction(cond)
          items = store.cache._match(cond)
          mapObj items, (key, data) ->
            if data then store.cache.set(deserialize(key), transform(data))
        else
          data = store.cache._get(cond)
          if data then store.cache.set(cond, transform(data))

    # stop the subscription onDelete
    clear = store.clear
    store.clear = (query, onDelete) ->
      clear query, ->
        # stop subscription
        store.subs.get(query)?()
        store.subs.delete(query)
        onDelete?()

    return store


# This is a little finicky here. The fetcher get {query, limit, offset}.
# But the subscription locally just gets query. So on the server, we use
# a shim to update match the query while on the client, its just the query anyways.
@createDDPListStore = (name, {ordered, cursor, minutes, limit}, fetcher) ->
  store = createRESTListStore(name, {limit, minutes}, fetcher)

  if Meteor.isServer
    publish(name, {ordered, cursor}, fetcher)
    store.update = (cond) ->
      refreshPub name, ({query}) -> query is cond or cond?(query)
    return store

  if Meteor.isClient
    store.subs = createCache()

    store.fetch = (query, callback) ->
      {limit, offset} = store.paging.get(query) or {limit:store.limit, offset:0}
      debug 'subscribe', name, query, limit + offset
      subscribe name, {query, limit, offset}, (sub) ->
        debug 'stop prev sub', name, query
        store.subs.get(query)?()           # stop the old subscription
        store.subs.set(query, sub.stop)    # set the new subscription
        store.cache.set(query, sub.data or [])
        sub.onChange (data) -> store.cache.set(query, data)
        callback?(store.respond(query, sub.data))

    # latency compensation
    store.update = (cond, transform) ->
      if transform
        if isFunction(cond)
          items = store.cache._match(cond)
          mapObj items, (key, data) ->
            if data then store.cache.set(deserialize(key), transform(data))
        else
          data = store.cache._get(cond)
          if data then store.cache.set(cond, transform(data))

    # stop the subscription and cleanup paging onDelete
    clear = store.clear
    store.clear = (query, onDelete) ->
      debug 'clear', name, query
      clear query, ->
        debug 'delete', name, query
        # stop subscription
        store.subs.get(query)?()
        store.subs.delete(query)
        store.paging.delete(query)
        onDelete?()

    return store
