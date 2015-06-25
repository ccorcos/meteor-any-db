# http://meteorpad.com/pad/fkf6pqbb6PvuKGfBW/pubs

counter = ->
  x = 0
  -> 
    x += 1
    x %= 1000000000

if Meteor.isServer

  @triggers = {}

  @count = 0
  Meteor.publish 'count', ->
    client = this._session.id
    this.added 'count', 'ID', {value:count}
    triggers[client] = => this.changed 'count', 'ID', {value:count}
    this.onStop -> delete triggers[client]
    return undefined


Meteor.methods
  inc: () -> 
    if Meteor.isServer
      count++
      for clientId, trigger of triggers
        trigger()

if Meteor.isClient
  @Counts = new Mongo.Collection('count')
  Meteor.subscribe('count')
  Template.main.helpers
    count: () -> Counts.findOne()
  Template.main.events
    'click button': () -> Meteor.call('inc')