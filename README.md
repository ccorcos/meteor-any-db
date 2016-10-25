[![Meteor Icon](http://icon.meteor.com/package/ccorcos:any-db)](https://atmospherejs.com/ccorcos/any-db)

# Meteor Any-Db [MAINTAINER WANTED]

This package allows you to use Meteor with any **database** or **data source**.

[Check out this article](https://medium.com/p/feb09105c343/).

# Getting Started

Simply add this package to your project:

    meteor add ccorcos:any-db

# API

This works with any arbitrary collection. Every document needs a unique `_id` field. We'll demonstrate this with Mongo, but you could easily use `ccorcos:neo4j` or `ccorcos:rethink` as well.

Subscriptions are limited to only one argument!

```coffee
Messages = new Mongo.Collection('messages')

# publish an ordered collection
AnyDb.publish 'messages', (roomId) ->
  # make sure any async methods are wrapped in a fiber.
  # every document needs a unique _id field.
  Messages.find({roomId}, {sort: {time: -1}}).fetch()

# subscriptions are limited to only one argument
sub = AnyDb.subscribe 'messages', roomId, (sub) ->
  console.log("sub ready", sub.data)
  sub.onChange (data) ->
    console.log("new sub data", sub.data)
sub.stop()

# publications must be manually refreshed if you want reactive data
Meteor.methods
  newMsg: (roomId, text) ->
    Messages.insert({roomId, text, time: Date.now()})
    # Ramda.js makes these refresh calls really clean
    AnyDb.refresh 'messages', R.propEq('roomId', roomId)
```
