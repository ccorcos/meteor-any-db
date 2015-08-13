# Meteor Any-DB

This package allows you to use Meteor with any **database** or **data source**.

# Getting Started

Simply add this package to your project:

    meteor add ccorcos:any-db

Rather than have mini-database on the client, the data for each subscription belongs to the subscription itself.
This package allows you to publish cursors or collections, ordered or unordered.

Unordered publications end up on the client as objects with id's as keys. Ordered publications end up on the client as arrays of documents. Every document must have a unique `_id` property.

Cursor publications have reactivity baked in, thus we can use Mongo cursors just as we always have. But if you want to use another database, you'll have to manage reactivity yourself. Whenever you write to the database, any publications that will be effected can be refreshed using `refreshPub(name, query)`. Now, publications have only two arguments, a query and some options. The options will typically be a limit or offset which does not effect whether the subscription should be refreshed or not.

# Examples

Publications are pretty simple:

```coffee
publish 'messages', {ordered: true, cursor: false}, ({roomId}, {limit}) ->
  Messages.find({roomId}, {limit, sort:{createdAt:-1}}).fetch()
```

There are two common patterns you might use for handling subscriptions depending on whether or not you want to show a loading animation:

```coffee
# without loading animation
sub = subscribe('message', {roomId}, {limit})
sub.onChange (messages) => @setState({messages})
sub.data # get the current data for the subscription
sub.stop() # stop the subscription

# with a loading animation
@setState({loading:true})
sub = subscribe 'messages', {roomId}, {limit}, ({data, onChange}) =>
  @setState({messages:data, loading:false})
  sub.onChange (messages) => @setState({messages})
```

Now if you're publishing a cursor, then the publication will send new data to the client automatically, but if you're not publishing a cursor, you need to tell the publication that the data has updated and it needs to refresh the publication. This typically happens on a write:

```coffee
Meteor.methods
  newMsg: (roomId, text) ->
    if Meteor.isServer
      Messages.insert({roomId, text, createdAt:Date.now()})
      refreshPub('messages', roomId)
```

This will not do latency compensation on the client, but it will make sure that the changes get updated on the client as soon as possible. If you want latency compensation on the client, this is something you can easily implement yourself around this package.



# TODO

create another package for stores
create another package for react-ui elements

stores with a store data component

pub -> db -> ... -> sub -> store

actions -> db -> pub...
        -> updates -> store


data name: db, store
action name: action, update
