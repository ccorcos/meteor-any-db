@Docs = new Mongo.Collection('docs')

doc = (i) ->
  {_id:"x#{i}", value:{number:i, double:i*2}}
  
if Meteor.isServer
  Meteor.startup ->
    if Docs.find().count() is 0
      for i in [0...10]
        Docs.insert(doc(i))

  Meteor.publish 'number', -> 
    Docs.find({}, {fields:{'value.number':1}})
  
  Meteor.publish 'double', -> 
    Docs.find({}, {fields:{'value.double':1}})

if Meteor.isClient
  Meteor.subscribe('number')
  Meteor.subscribe('double')

  Template.main.helpers
    docs: () -> Docs.find()