# TODO

- you should be able to create an observer before subscribing.
- subscriptions need to be immutable. its going to get out of hand
  it will be slightly less efficient but it will be worth it.
- Model and DB are different.

- latency compensation is a bit trickier than it seems
- 

- simple chat application
- latency compensation

- neo4j example
- postgresql example
- fine grained reactivieity

- PostgresQL, Neo4j, Mongo, Rethink with changefeeds

- sub onready?
- client initiated update as opposed to poll and diff
- homebrewed dependency publication dependency tracking
- subscriptions from server to server

# How it works

## Motivation

(Please help with references and corrections!)

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

## Implementation

### Server

This database API is fundamentally simple. `DB.publish(name, ms, query)` will 
poll-and-diff a `query` function every `ms` milliseconds and publish the results
using `Meteor.publish`. `query` must return a collection (array of objects) and every
document must contain an `_id` key.

Under the hood, `DB.publish` does a couple nice things for you. When it creates a
Meteor publication, it also gets a subscription id, `subId`, from the client to identify
which subscription this document belongs to.
Also, [DDP does not yet support ordered queries](1) and most database queries will likely
need to be ordered nso we need a work around. 
Every DDP message related to `addedBefore` or `movedBefore` takes an additional key
specififying both the `subId` and `before` in a '.' separated string. This is a super 
convenient workaround. Merge-box will prevent the same data from being sent over
twice so sending these values in different keys means that the `subId` will only be sent
once, but we need that value so we know what subscription the order refers to. Combining
them in the same key is a nice elegant way of solving this issue. 

#### Improvements

Later, I think it would be awesome if we could support some dependency tracking so that
some publications will automatically poll-and-diff immediately if certain criteria are met
during a write from a `Meteor.method`. This shouldn't be too hard, but it needs to be well
thought-out.

### Client

We can get away without any mini-databases on the client by delegating all the 
database stuff to the database (where it should be)! On the client, we have one
object -- a subscription -- that encapsulates everything data-related in Meteor: 
`Meteor.subcribe`, `Mongo.Collection`, and  `Mongo.Cursor`.

We create a subscription in much the same way we did before: 
`sub = DB.subscribe(name, args...)`.
This function basically just creates a `subId` and calls the appropriate Meteor publication
we created with `DB.publish(name, ms, query)` and the args are passed directly to the 
query function as arguments. The subscription object, `sub`, can now be used like this:
- `sub.stop()` will stop the Meteor subscription.
- `sub.observeChanges` and `sub.observe` work just like `Cursor.observe` and `Cursor.observeChanges`.
- `sub.fetch()` is a Tracker-aware (reactive function) that will fetch all the documents
in this subscription. 

#### Improvements

If you use React with components that all have PureRenderMixin (which is recommended), 
then `sub.fetch()` is all you need. React's DOM-diffing will do all the hard work for you. 
However, this is not how Blaze works. Blaze relies on fine-grained reactivity. Thus to get
good performance out of Blaze, we'll need to build some concept of cursors (hopefully using
lenses!) so that we can limit what documents and fields are fetched and reactive.


[1]:https://github.com/meteor/meteor/blob/e2616e8010dfb24f007e5b5ca629258cd172ccdb/packages/ddp/DDP.md#procedure-2