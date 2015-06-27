# Meteor Any-db

This package allows you to use Meteor with any database or data source. Rather than have a mini-database on the client, we simply have a subscription/cursor object that represents the results of a server-side query. With the help of merge-box, we're only sending the minimal amount of data to the client. 

The most basic implementation is simply polling and diffing the results of a query over some interval for each user's subscription. Note that this query can return arbitary data -- data from a database query, or some 3rd party REST API.

You can also turn off polling and simply trigger a "refresh" from the client. Rather than using a `Meteor.method` to get data from the server, this will efficiently send only the changes down to the client.

You can also define dependencies for your publications so that you can trigger those publications to refresh elsewhere on the server (typically on a database write). This gives you instantaneous reactivity.

Lastly, this package can reactively publish any datasource that supports [`Cursor.observeChanges`](observeChanges). Thus, you can use it with Meteor's Mongo package as-is, and it could easily support other databases with realtime changefeeds.

**Help**

I could use some help building database drivers for other databases. This gets a little tricky when it comes to wrapping their API into fibers. I've been trying to do this with RethinkDB and failing.

## How it works

### Motivation

(Please help with references and corrections. I could be wrong about some of these things. I'm just going off the top of my head...)

First, let me go over the current state of Mongo integration with Meteor.

Without Oplog tailing, Meteor will watch for database writes locally and update
the subscriptions on those writes. They do this by effectively reimplementing
Mongo in Javascript, aka Minimongo. This is a huge pain, but has had great success.
If you are running two Meteor servers, however, then these servers aren't aware of
each others subscriptions. In this case, Meteor resorts to polling Mongo every 10 seconds
diffing the results, and updating the subscriptions accordingly.

With Oplog tailing, Meteor watches the the Mongo operation log and updates any subscriptions
that depend on those changes immediately. This works great across multiple servers but if 
Mongo has a high rate of writes, then your servers will struggle to keep up with the oplog
and take up all the processing power. In this case, Meteor again resorts to a 10 second
poll-and-diff.

So if we were to implement other database drivers, it seems the 10 second poll-and-diff
would be a could place to start. This is actually pretty simple since Meteor lets us write
arbitrary data to our publications. Thus, the challenging part is the client. 

Implementing mini[db] for every database is clearly not a scalable solution.
In fact, its always bothered me how I end up writing the same exact Mongo query twice -- 
once in `Meteor.publish` and once in `Template.helpers`. Also, with more complicated
database queries you might run with Neo4j, there's no way to replicate these queries 
on the client without the whole corpus of data (e.g. min-flow/max-cut and other graph queries).

### Implementation

#### Server

Each publication accepts a query function which must return a collection of documents that must contain a unique `_id` field. [DDP does not yet support ordered queries](DDP_spec) so every DDP message related to `addedBefore` or `movedBefore` has an additional key specifying which subscription and which position.

Publications can also specify dependency keys which will trigger them to update immediately when those dependencies are triggered.

#### Client

On the client, we have one object that encapsulates everything data-related in Meteor: `Meteor.subcribe`, `Mongo.Collection`, and  `Mongo.Cursor`.

`DB.createSubscription` will create a `DBSubscriptionCursor` object for you. You can start and stop the subscription by calling `sub.start()` and `sub.stop()`. You can also use it as a cursor with `sub.observe` and `sub.observeChanges`. And you can fetch all the documents using `sub.fetch()` and this function is Tracker-aware / reactive.

## Getting Started

This package depends on the [`diff-sequence`](https://github.com/meteor/meteor/tree/devel/packages/diff-sequence) package which isn't part of Meteor 1.0. Until then, you'll have to manually include this package in your project. So first, copy this package into your `packages/` directory for your project (you can delete this when the next version of Meteor is released).

    git clone https://github.com/ccorcos/meteor-diff-sequence

Then add this package to your project

    meteor add ccorcos:any-db

### `DB.publish(options)` 

`options` object fields:
- `name`: name of the publication. (required) 
- `query`: a function that returns a collection of documents. Each document must contain a unique `_id` field. This function will be passed arguments when the client subscribes. (required if you don't pass a cursor function)
- `cursor`: a function that returns a cursor that implements [`Cursor.observeChanges`](observeChanges). This function gets arguements when the client subscribes. (required if you dont pass a query function)
- `ms`: the interval over which to poll an diff. If you dont pass a value, then the subscription must be triggered. (optional)
- `depends`: a function that returns an array of keys which will trigger the publication to rerun. Also gets arguments when the client subscribes. (optional)

**Example:**

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


### `sub = DB.createSubscription(name, args...)`

This function returns a `DBSubscriptionCursor` object. 

- `name`: name of the publication to subscribe to.
- `args...`: arguments to be passed to the `query`, `cursor`, and `depends` functions in the publication, much like with `Meteor.subscribe` and `Meteor.publish`.

`sub` represents a subscription, an observer, and a cursor.

- `sub.start()`: starts the subscription with the arguments passed into `DB.createSubscription`.
- `sub.stop()`: stops the subscription.
- `sub.observe`: observes the cursor with the same API as Meteor's [`Cursor.observe`](observe). You must use the positional callbacks (`addedAt`, etc.)
- `sub.observeChanges`: observes changes to the cursor with the same API as Meteor's [`Cursor.observeChanges`](observeChanges). You must use the positional callbacks (`addedBefore`, etc.).
- `sub.fetch()`: returns a collection of documents. This is a Tracker-aware (reactive) function.
- `sub.trigger()`: triggers the publication to rerun to check for any changes.

**Latency Compensation**

The subscription object is actually an observer of the DDP messages. This it has the following methods: `addedBefore`, `movedBefore`, `changed`, `removed`. Using these methods, we can optimistically add changes to our subscription before waiting for a round trip from the server. However, these changes may get rejected by the server, so we also need an "undo" function which will undo these optimistic changes when the true results come back from the server.

- `sub.addUndo(id, func)`: a function that will be called when the next DDP msg is received for a document matching the `id`. This is used to undo optimistic changes to the UI.

**Example**

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

Note how we're using the subscription's observer methods to add and undo the optimistic change. We also have to create the `_id` on the client and send that to the server. This way, we can track the document as it goes to the server and back.

You also have to make sure to catch any errors and undo the optimistic UI change. If an error occurs on the server, we'll never see a DDP message for that id come through to the client. For example:

    Template.main.events
      'click .newMsg': (e,t) ->
        elem = t.find('input')
        input = elem.value
        id = Random.hexString(24)
        Meteor.call 'newMsg', Session.get('roomId'), id, input, (err, result) -> 
          if err then msgs.handleUndo(id)
        elem.value = ''

## Examples

There are several [examples](/examples/) to check out, but must of them are really just end-to-end tests. The best example to check out is the [chatroom](/examples/chatroom/). This example uses Neo4j as a database to create a chatroom. Check it out [in action](https://www.youtube.com/watch?v=Av1EsSMB33w&feature=youtu.be). 


# TODO

- Database drivers:
  - rethinkdb
  - redis
  - postgresql
  - mysql
- Subscriptions from server to server


[DDP_spec]:https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#procedure-2
[observeChanges]: http://docs.meteor.com/#/full/observe_changes
[observe]:http://docs.meteor.com/#/full/observe
