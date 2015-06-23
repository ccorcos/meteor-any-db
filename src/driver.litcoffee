# Any DB for Meteor!

## Utilities

Here are some functions we're going to be using:

[Ramda](ramdajs.com/docs/) is a super functional programming toolbox for JavaScript. 
[Its way better than lodash or underscore.](https://www.youtube.com/watch?v=m3svKOdZijA).


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

[Lodash](https://lodash.com/docs#isPlainObject) would be nice right about now.

    isPlainObject = (x) ->
      Object.prototype.toString.apply(x) is "[object Object]"

Debug printing

    # debug = console.log.bind(console)
    debug = (->)


Recursive functions that join two nested objects. `merge` is immutable. `extend` is mutable.
`R.clone` is deep.

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

DDP "change" messages will set fields to `undefined` 
[if they are meant to be unset.](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L172).
So we can call `extendDeep` then `deleteUndefined` update changes.

    deleteUndefined = (obj) ->
      for k,v of obj
        if isPlainObject(v)
          deleteUndefined(v)
        else if v is undefined
          delete obj[k]
      return obj

Its not [particularly clear in the DDP spec](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#messages-2)
if the fields object contains nested EJSON objects. All I know is that they 
[pass it directly into `$set`](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L179)
which, for nested objects, requires '.' separated strings.

This function simply translates an object of "fields" with '.' separated keys for nested
fields and translates that into a nested object.

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

The DDP spec doesnt talk much about this but it looks like DDP sends funny ID's for the 
documents. They use the [`mongo-id` package](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L139)
but I get an error when I use it. So I [copied it](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo-id/id.js#L80).

    parseId = (id) ->
      if id is ""
        return id
      else if id is '-'
        return undefined
      else if id.substr(0, 1) is '-'
        return id.substr(1)
      else if id.substr(0, 1) is '~'
        return JSON.parse(id.substr(1)).toString()
      else
        return id

## DB

Define the global `DB` object on both the client and the server.

    @DB = {}

`DB.name` will be used as an identifier in DDP messages.

    DB.name = 'ANY_DB'

### Publish

`DB.publish` will poll-and-diff a query function that returns a collection. Each document
in the collection MUST contain an `_id` field.

There are a few ways that Meteor gets reactivity out of Mongo. Without Oplog support
Meteor inspects database writes and sends updates immediately to any subscriptions that 
depend on those writes. However, if you are running two servers (e.g. east and west coast servers),
those changes are updated via a 10 second poll-and-diff.
If you are using Oplog tailing, then both servers are watching the operation log messages right off
of Mongo and two different servers will update immediately. However, this is also limited. 
If Mongo has lots of writes (maybe you have 1M concurrent users or something)
then each CPU will struggle to keep up with the Oplog. In this case, Meteor will resort back
to the 10 second poll-and-diff again.

All that said, [Meteor does poll-and-diff does internally](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/polling_observe_driver.js#L176)
so [we can use their internal package that does a bunch of hard stuff](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/diff-sequence/diff.js#L7)!


#### `DB.publish(name, ms, query)`
- `name`: name of the publication, so you can do `DB.subscribe(name, args...)`
- `ms`: millisecond interval to poll-and-diff.
- `query`: a function that returns a collection of documents that must contain an `_id` field!

(markdown/litcoffee quirk!)

    if Meteor.isServer
      DB.publish = (name, ms, query) ->

A friendly warning...

        if ms < 1000
          console.warn("Polling every #{ms} ms. This is pretty damn fast!")

When you return a `Mongo.Cursor` from `Meteor.publish`, [it calls this function](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/mongo/collection.js#L302).
We'll use a publication id to sepcify which publications contain these documents. 

        Meteor.publish name, (pubId, args...) ->
          pub = this

          # pass the arguments to the query function
          poll = () -> apply(query, args)

[DDP doesnt support ordered document collections yet](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#procedure-2), 
so we don't have `addedBefore`. However, we could be doing some advanced sorting in Neo4j or something
so we'll want to support that. Thus we'll add a key, `DB.name` to all position-based callbacks as a shim.
The format of the message will be the publication id and the position separated by a dot.

          # Get the initial data. Add them in order to the end.
          docs = poll()
          for doc in docs
            id = doc._id
            fields = omit(["_id"], doc)
            # null means its at the end of the collection
            fields[DB.name] = "#{pubId}.null"
            pub.added(DB.name, id, fields)

          # Tell the client that the subscription is ready
          pub.ready()

          # The observer needs to publish to the correct database name
          # and send the pubId and position.
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

We can parse the `pubId` and `before` on the other side with this function.

    parseDDPFields = (msg) ->
      [pubId, before] = msg.fields[DB.name]?.split('.') or []
      if before is "null" then before = null
      return [pubId, before]

### Subscriptions

In this package, the notion of a subscription encapsulates everything
data-related in Meteor: `Meteor.subcribe`, `Mongo.Collection`, and  `Mongo.Cursor`.

We don't want to have to implement `minimongo` and `miniX` for every database. 
When you're building a Meteor app, you're pretty much replicating these queries twice
anyways, once in `Meteor.publish` and again in `Template.helpers`. Thus we delegate 
all the database stuff off the client. We can call `sub.stop()` which will stop the
subscription. We can call `sub.observeChanges` which is the same as the `Cursor.observeChanges` API.
We can call `sub.fetch()` which is a Tracker-aware (reactive function) that returns
a collection of documents. 

Another thing to mention is data mutability. 
I'm all about immutable data as a programming pattern and mutable data creates some frustrations here, 
but it allows us to write more efficient code. `DB.docs` holds every document thats published with `DB.publish`.
Its a simple hash-map of `_id`'s.
They documents are passed by reference to each subscription that depends on them.
This way, when we change documents in `DB.docs`, they'll change the docs in all publications as well.
When you use `sub.fetch` or `sub.observeChanges` you are returned a deep clone of the collection or document
so you don't to worry about mutating something bad.


    # Should be able to do this on the server as well with Fibers, but we'll do that later
    if Meteor.isClient

All documents published through `DB.publish`.

      DB.docs = {}

All subscriptions -- this class is defined later.

      DB.subscriptions = {}

      DB.reset = ->
        DB.docs = {}
        for collection in DB.subscriptions
          collection.reset()

#### `DDP.registerStore`

Get the DDP connection.

      DB.connection = if Meteor.isClient then Meteor.connection else Meteor.server
      
[Copying how MDG does it with Mongo.](https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp-client/livedata_connection.js#L1343)
This is poorly documented...

      DB.connection.registerStore DB.name,
        beginUpdate: (batchSize, reset) ->

Missing an optimization here.

          # if batchSize > 1 or reset
          #   # pauseObservers
          if reset
            DB.reset()

DDP messages assigned to the `DB.name` data store end up here.

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
            if doc
              throw new Error("Expected not to find a document already present for an add")
            [pubId, before] = parseDDPFields(msg)
            doc = omit([DB.name], msg.fields)
            doc._id = id
            DB.docs[id] = doc
            # pass the doc by reference!
            DB.subscriptions[pubId].addedBefore(doc, before)
            return

          if msg.msg is 'removed'
            if not doc
              throw new Error("Expected to find a document already present for removed")
            delete DB.docs[id]
            for key, sub of DB.subscriptions
              sub.removed(id)
            return

          if msg.msg is 'changed'
            if not doc
              throw new Error("Expected to find a document to change")
            [pubId, before] = parseDDPFields(msg)
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
          # resumeObservers

        # // Called around method stub invocations to capture the original versions
        # // of modified documents.
        # saveOriginals: function () {
        #   self._collection.saveOriginals();
        # },
        # retrieveOriginals: function () {
        #   return self._collection.retrieveOriginals();
        # }


#### DBSubscription Class

The subscription class manages `Meteor.subcribe`, `Mongo.Collection`, and  `Mongo.Cursor`.
All the data returned from here ought to be cloned so developers can't mess with the 
internal mutable structures.

      class DBSubscription
        constructor: (@pubId) ->
          i = 0
          @count = -> i++
          @results = []
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
          i = @count()
          @observers[i] = callbacks
          return {stop: => delete @observers[i]}

        fetch: ->
          @dep.depend()
          return clone(@results)

`registerStore` from above will call these functions on the appropriate subscription
based on the `pubId` (pubId and subId are basically synonyms depending on the perspective).
Docs are passed by references so changes make sure not to clone them when storing in the
subscription results. However, make sure to clone it before passing it to devs.

        addedBefore: (doc, before) ->
          if before is null
            @results.push(doc)
          else
            i = findIndex(propEq('_id', before), @results)
            if i < 0 then throw new Error("Expected to find before _id")
            @results.splice(i,0,doc)
          for key, observer in @observers
            observer.addedBefore(doc._id, omit(['_id'], doc), before)
          @dep.changed()
        
        movedBefore: (id, before) ->          
          i = findIndex(propEq('_id', id), @results)
          if i < 0 then throw new Error("Expected to find id: #{id}")
          [doc] = @results.splice(i,1)
          if before
            i = findIndex(propEq('_id', before), @results)
            if i < 0 then throw new Error("Expected to find before _id: #{before}")
            @results.splice(i,0, doc)
          else
            @results.push(doc)
          for key, observer in @observers
            observer.movedBefore(id, before)
          @dep.changed()
        
        changed: (id, fields) ->
          # the results doc should be updated because addedBefore saves
          # the object by reference and the change is updated in `registerStore`
          for key, observer in @observers
            observer.changed(id, clone(fields))
          @dep.changed()
        
        removed: (id) ->
          i = findIndex(propEq('_id', id), @results)
          if i < 0 then throw new Error("Expected to find id")
          @results.splice(i,1)
          for key, observer in @observers
            observer.removed(id)
          @dep.changed()

        reset: ->
          @results = []
          @dep.changed()



#### `DB.subscribe`

The client must tell the server a publication id. This is used to sort out
the documents coming in over DDP. We'll use a simple counter to generate ids.

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

      


## TODO
- multiple subscriptions at the same time
- what happens when cleared?
- fine grained reactivieity
- latency compensation
- MySQL, PostgresQL, Neo4j, Redis, Rethink