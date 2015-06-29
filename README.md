# Meteor Any-DB

This package allows you to use Meteor with any **database** or **data source**. 

# Getting Started

Simply add this package to your project:

    meteor add ccorcos:any-db

Rather than have a mini-database on the client, we simply have a subscription-cursor object that represents the results of a server-side query. To keep Meteor reactive, we specify the dependencies for each publication and trigger them to update when necessary. Here's a simple example for a chatroom:

```coffee
# on the server
DB.publish
  name: 'msgs'
  query: (roomId) -> fetchMessages(roomId)
  depends: (roomId) -> ["chatroom:#{roomId}"]

# on the client
msgs = DB.createSubscription('msgs', roomId)
```

In this example, `fetchMessages` returns a collection of documents that must contain unique `_id` fields. This could mean reading from a file, fetching data from a 3rd party API, or querying a database. Anything in your query that is asynchronous, must be wrapped in a fiber using [`Meteor.wrapAsync`](http://docs.meteor.com/#/full/meteor_wrapasync). `depends` is a function returning an array of keys. These keys will be used to trigger the query to rerun, updating the user's publication.

`msgs` is a subscription-cursor-observer-like object. Like a subscription, you can `.start(onReady)` and `.stop()` it. Like a cursor, you can `.observe`, `.observeChanges`, or `.fetch()`. Thus you can use it right in your blaze templates.

```coffee
Template.messages.onRendered ->
  msgs.start()

Template.messages.onDestroyed
  msgs.stop()

Template.messages.helpers
  msgs: () -> msgs
```

Like an observer `msgs` has `.addedBefore`, `.movedBefore`, `.changed`, and `.removed` just like Meteor's [`Cursor.observeChanges`][observeChanges]. This comes in handy, not only for the internals of this package, but for latency compensation. When performing a write operation, we can use these observer methods to simulate the change on the client and provide an undo operation that will run when the client recieves a document with the same `_id` from the server. This means that document ids must be created on the client. You can generate ids using `DB.newId()` which simply calls `Random.hexString(24)`. 

```coffee
Meteor.methods
  newMsg: (roomId, msgId, text) ->
    if Meteor.isServer
      createMessage(roomId, msgsId, text)
      DB.triggerDeps("chatroom:#{roomId}")
    else
      fields = {_id: msgId, text: text, unverified: true}
      before = msgs.docs[0]?._id or null
      msgs.addedBefore(msgId, fields, before)
      undo = -> msgs.removed(msgId)
      msgs.addUndo(msgId, undo)
```

After a write on the server, we'll trigger an update to any subscriptions based on the dependency keys specified in the publications using `DB.triggerDeps`.

When you call this method, its important to catch if there are any errors and handle undo'ing the latency compensation. Otherwise, if the server throws an error on this method and the document isn't written, the latency-compensated document will live forever on the client.

```coffee
msgId = Random.hexString(24)
Meteor.call 'newMsg', roomId, msgId, text, (err, result) -> 
  if err then msgs.handleUndo(msgId)
```

That's all there is to it! Now you can use any database reactively with Meteor!

# Bells and Whistles

## Publishing Cursors

This package can also publish any cursor that implements [`Cursor.observeChanges`][observeChanges]. Meteor's `mongo` pacakge works right out of the box:

```coffee
# on the server
DB.publish
  name: 'msgs'
  cursor: (roomId) -> Msgs.find({roomId: roomId})
```

But since we aren't using `minimongo` anymore, you'll still have to do latency compensation, but you won't need to `triggerDeps`.

```coffee
Meteor.methods
  newMsg: (roomId, msgId, text) ->
    if Meteor.isServer
      Msgs.insert({roomId: roomId, _id: msgsId, text: text})
    else
      fields = {_id: msgId, text: text, unverified: true}
      before = msgs.docs[0]?._id or null
      msgs.addedBefore(msgId, fields, before)
      undo = -> msgs.removed(msgId)
      msgs.addUndo(msgId, undo)
```

**Help**

I could use some help building drivers for reactive databases like Redis and RethinkDB.
All we need to do is implement `observeChanges` on a query cursor. There are also other
other tools for making MySQL and Postgres reactive as well.

## Publishing REST APIs

This package is also suitable for publishing data continuously from REST APIs. Typically, you might use `Meteor.methods`, calling it periodically from the client using `Meteor.setInterval` to get updated results. 

```coffee
Meteor.methods
  events: (location) ->
    params = {app_key: EVENTFUL_API_KEY, location: location}
    HTTP.get("http://api.eventful.com/json/events/search", {params: params})?.data
```

This approach sends a lot of redundant data over the network every time you call this method. Using this package, `DB.publish` uses `merge-box` and `diff-sequence` under the hood to efficiently send only the minimal amount of data over the network.

```coffee
DB.publish
  name: 'events'
  query: (location) ->
    params = {app_key: EVENTFUL_API_KEY, location: location}
    response = HTTP.get("http://api.eventful.com/json/events/search", {params: params})
    response?.data?.events?.map((event) ->
      event._id = event.id
      delete event['id']
      return event
    ) or []
  ms: 10000
```

This will update all publications every 10 seconds, specified by the `ms` option. Note that every document must have a unique `_id`! Alternatively, you can leave out `ms` option and trigger the subscription to refresh from the client like an old-school refresh button.

```coffee
events = DB.createSubscription('event', 'Los Angeles, CA')
events.start()

Template.events.events
  'click .refresh': ->
    events.trigger()
```

# Examples

There are several [examples](/examples/) to check out, but most of them are really just end-to-end tests. The best example to check out is the [chatroom](/examples/chatroom/). This example uses Neo4j as a database to create a chatroom. 

# How it works

The codebase is actually pretty straightforward and I made sure to include LOTS of comments. 
There are also plenty links to the Meteor codebase in the comments describing how I figured things out that are currently undocumented. Feel free to [dive in](/src/db.coffee)!

## Server

Each publication accepts a query function which must return a collection of documents that must contain a unique `_id` field. [DDP does not yet support ordered queries][DDP_spec] so every DDP message related to `addedBefore` or `movedBefore` has an additional (salted) key-value specifying the subscription and position.

## Client

On the client, we have an object, `DBSubscriptionCursor`, that encapsulates everything data-related in Meteor: `Meteor.subscribe`, `Mongo.Collection`, and  `Mongo.Cursor`. We simple use `connection.registerStore` to register a data store and treat `DBSubscriptionCursor` as an observer, calling the appropriate [`Cursor.observeChanges`][observeChanges] method on each active subscription.

# Docs

#### `DB.publish(options)` 

`options` object fields:
- `name`: name of the publication. (required) 
- `query`: a function that returns a collection of documents. Each document must contain a unique `_id` field. This function will be passed arguments when the client subscribes. (required if you don't pass a cursor function)
- `cursor`: a function that returns a cursor that implements [`Cursor.observeChanges`][observeChanges]. This function gets arguements when the client subscribes. (required if you dont pass a query function)
- `ms`: the interval over which to poll an diff. If you dont pass a value, then the subscription must be triggered. (optional)
- `depends`: a function that returns an array of keys which will trigger the publication to rerun. Also gets arguments when the client subscribes. (optional)

**Example:**

```coffee
DB.publish
  name: 'msgs'
  query: (roomId) ->
    Neo4j.query """
      MATCH (room:ROOM {_id:"#{roomId}"})-->(msg:MSG)
      RETURN msg
      ORDER BY msg.createdAt DESC
    """
  depends: (roomId) -> 
    ["chatroom:#{roomId}"]

Meteor.methods
  newMsg: (roomId, id, text) ->
    check(id, String)
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      Neo4j.query """
        MATCH (room:ROOM {_id:"#{roomId}"})
        CREATE (room)-[:OWNS]->(:MSG #{Neo4j.stringify(msg)})
      """
      DB.triggerDeps("chatroom:#{roomId}")
```


#### `sub = DB.createSubscription(name, args...)`

This function returns a `DBSubscriptionCursor` object. 

- `name`: name of the publication to subscribe to.
- `args...`: arguments to be passed to the `query`, `cursor`, and `depends` functions in the publication, much like with `Meteor.subscribe` and `Meteor.publish`.

`sub` represents a subscription, an observer, and a cursor.

- `sub.start()`: starts the subscription with the arguments passed into `DB.createSubscription`.
- `sub.stop()`: stops the subscription.
- `sub.observe`: observes the cursor with the same API as Meteor's [`Cursor.observe`][observe]. You must use the positional callbacks (`addedAt`, etc.)
- `sub.observeChanges`: observes changes to the cursor with the same API as Meteor's [`Cursor.observeChanges`][observeChanges]. You must use the positional callbacks (`addedBefore`, etc.).
- `sub.fetch()`: returns a collection of documents. This is a Tracker-aware (reactive) function.
- `sub.trigger()`: triggers the publication to rerun to check for any changes.

**Latency Compensation**

The subscription object is actually an observer of the DDP messages with the following methods: `addedBefore`, `movedBefore`, `changed`, `removed`. Using these methods, we can optimistically add changes to our subscription before waiting for a round trip from the server. However, these changes may get rejected by the server, so we also need an "undo" function which will undo these optimistic changes when the true results come back from the server.

- `sub.addUndo(id, func)`: Calls a function `func` when the next DDP msg is received for a document matching the `id`. This is used to undo optimistic changes to the UI.

**Example**

```coffee
if Meteor.isClient
  @msgs = DB.createSubscription('msgs', roomId)
  @msgs.start()

Meteor.methods
  newMsg: (roomId, id, text) ->
    check(id, String)
    check(text, String)
    msg = {
      _id: id
      text: text
      createdAt: Date.now()
    }
    if Meteor.isServer
      Neo4j.query """
        MATCH (room:ROOM {_id:"#{roomId}"})
        CREATE (room)-[:OWNS]->(:MSG #{Neo4j.stringify(msg)})
      """
      DB.triggerDeps("chatroom:#{roomId}")
    else
      fields = R.pipe(
        R.assoc('unverified', true), 
        R.omit(['_id'])
      )(msg)
      @msgs.addedBefore(id, fields, @msgs.docs[0]?._id or null)
      @msgs.addUndo id, => @msgs.removed(id)
```

Note how we're using the subscription's observer methods to add and undo the optimistic change. We also have to create the `_id` on the client and send that to the server. This way, we can track the document as it goes to the server and back.

If an error occurs on the server, we'll never see a DDP message for that id come through to the client so you'll also have to make sure to catch any errors and undo the optimistic UI change. For example:

```coffee
Template.main.events
  'click .newMsg': (e,t) ->
    elem = t.find('input')
    text = elem.value
    id = Random.hexString(24)
    Meteor.call 'newMsg', Session.get('roomId'), id, text, (err, result) -> 
      if err then msgs.handleUndo(id)
    elem.value = ''
```

# TODO

- Subscriptions from server to server
- Use Tracker for pub/sub dependencies
- Automated tests!
- Database drivers:
  - rethinkdb
  - redis
  - postgresql
  - mysql


[DDP_spec]: https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#procedure-2
[observeChanges]: http://docs.meteor.com/#/full/observe_changes
[observe]: http://docs.meteor.com/#/full/observe
