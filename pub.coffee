{DB_KEY} = AnyDb # Spoofing a Mongo collection name to hack around DDP

debug = (->)
if Meteor.settings.public?.log?.pub
  debug = console.log.bind(console, 'pub')

# flatten a deep object into fields separated with '.'
obj2Fields = (obj={}) ->
  dest = {}
  for key, value of obj
    if U.isPlainObject(value)
      deeperFields = obj2Fields(value)
      for k,v of deeperFields
        dest["#{key}.#{k}"] = v
    else
      dest[key] = R.clone(value)
  return dest

salter = -> Random.hexString(10)

# publish with the subscriptionId and the position
createOrderedObserver = (pub, subId) ->
  addedBefore: (id, fields={}, before) ->
    U.set([DB_KEY, subId], "#{salter()}.#{before}", fields)
    pub.added(DB_KEY, id, obj2Fields(fields))
  movedBefore: (id, before) ->
    fields = {}
    U.set([DB_KEY, subId], "#{salter()}.#{before}", fields)
    pub.changed(DB_KEY, id, obj2Fields(fields))
  changed: (id, fields) ->
    pub.changed(DB_KEY, id, fields)
  removed: (id) ->
    pub.removed(DB_KEY, id)

# pubs[name][serialize(query)][subId] = refresh
AnyDb.pubs = {}

AnyDb.refresh = (name, queryCond) ->
  if AnyDb.pubs[name]
    queries =  Object.keys(AnyDb.pubs[name])
      .map(U.deserialize)
      .filter(queryCond)
      .map(U.serialize)
    debug 'refresh', name
    queries.map (query) ->
      # defer these updates so they dont block methods or subscriptions
      U.mapObj AnyDb.pubs[name][query], (subId, sub) -> Meteor.defer -> sub.refresh()

AnyDb.transform = (name, queryCond, xform) ->
  if AnyDb.pubs[name]
    queries =  Object.keys(AnyDb.pubs[name])
      .map(U.deserialize)
      .filter(queryCond)
      .map(U.serialize)
    debug 'transform', name
    queries.map (query) ->
      # defer these transforms so they dont block methods or subscriptions
      U.mapObj AnyDb.pubs[name][query], (subId, sub) -> Meteor.defer -> sub.transform(xform)

AnyDb.publish = (name, fetcher) ->
  Meteor.publish name, (query) ->
    # unblock this publication so others can be processed while waiting
    # for HTTP requests so they arent fetched synchronously in order.
    # Thanks again Arunoda!
    this.unblock()
    # subscribe undefined comes through as null and this is annoying when you
    # want to refresh a publication matching undefined
    if query is null then query = undefined

    pub = this
    subId = pub._subscriptionId

    sub =
      subId: subId
      docs: []
      name: name
      query: query

    # fetch documents
    sub.fetch = -> fetcher.call(pub, query)
    # observer which sends DDP messages through merge-box through
    # the publication along with subId and position information.
    sub.observer = createOrderedObserver(pub, subId)
    # fetch document again, diff, and publish
    sub.refresh = ->
      lap = U.stopwatch()
      debug('refreshing', name, subId)
      newDocs = sub.fetch()
      DiffSequence.diffQueryChanges(true, sub.docs, newDocs, sub.observer)
      sub.docs = newDocs
      debug('refreshed', name, subId, lap(), 's')
    # transform data, rather than refresh if we know for sure what the change
    # will be.
    sub.transform = (xform)->
      lap = U.stopwatch()
      debug('transforming', name, subId)
      newDocs = xform(R.clone(sub.data))
      DiffSequence.diffQueryChanges(true, sub.docs, newDocs, sub.observer)
      sub.docs = newDocs
      debug('transformed', name, subId, lap(), 's')

    do ->
      lap = U.stopwatch()
      debug('start', name, subId)
      sub.docs = sub.fetch()
      sub.docs.map (doc) ->
        id = doc._id
        fields = R.clone(doc)
        delete fields._id
        sub.observer.addedBefore(id, fields, null)
      pub.ready()
      debug('ready', name, subId, lap(), 's')

    # register and unregister publication
    key = U.serialize(query)
    U.set [name, key, subId], sub, AnyDb.pubs
    pub.onStop ->
      debug('stop', name, subId)
      U.unset [name, key, subId], AnyDb.pubs
