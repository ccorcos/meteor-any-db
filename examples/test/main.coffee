###
@Docs = new Mongo.Collection('docs')

# create some pretty arbitrary documents
doc = (i) ->
  {_id:"x#{i}", number:i, double:i*2}

if Meteor.isServer
  Meteor.startup ->
    if Docs.find().count() is 0
      for i in [0...10]
        Docs.insert(doc(i))

  # two different publications that publish a specific field for
  # the same documents
  Meteor.publish 'number', -> 
    Docs.find({}, {fields:{number:1}})
  
  Meteor.publish 'double', -> 
    Docs.find({}, {fields:{double:1}})


if Meteor.isClient
  Meteor.subscribe('number')

  Docs.find({}, {sort:{number:1}}).observeChanges 
    addedBefore: (id, fields, before) ->
      console.log("added", id, fields)
    
    changed: (id, fields) ->
      console.log("changed", id, fields)
    
    movedBefore: (id, before) ->
      console.log("movedBefore", id, before)
    
    removed: (id) ->
      console.log("removed", id)
    
  Meteor.subscribe('double')
  

# Open up the console on the client and you'll see 10
# added messages followed by 10 changed messages. As expected :)

# added x0 Object
# added x1 Object
# added x2 Object
# added x3 Object
# added x4 Object
# added x5 Object
# added x6 Object
# added x7 Object
# added x8 Object
# added x9 Object
# changed x0 Object
# changed x1 Object
# changed x2 Object
# changed x3 Object
# changed x4 Object
# changed x5 Object
# changed x6 Object
# changed x7 Object
# changed x8 Object
# changed x9 Object

###






@Docs = new Mongo.Collection('docs')

doc = (i) ->
  # {_id:"x#{i}", number:i, double:i*2}
  {_id:"x#{i}", value:{number:i, double:i*2}}
  

if Meteor.isServer
  Meteor.startup ->
    if Docs.find().count() is 0
      for i in [0...10]
        Docs.insert(doc(i))

  Meteor.publish 'number', -> 
    # Docs.find({}, {fields:{number:1}})
    Docs.find({}, {fields:{'value.number':1}})
  
  Meteor.publish 'double', -> 
    # Docs.find({}, {fields:{double:1}})
    Docs.find({}, {fields:{'value.double':1}})

if Meteor.isClient
  Meteor.subscribe('number')

  # Docs.find({}, {sort:{number:1}}).observeChanges 
  Docs.find({}, {sort:{'value.number':1}}).observeChanges 
    addedBefore: (id, fields, before) ->
      console.log("added", id, fields)
    
    changed: (id, fields) ->
      console.log("changed", id, fields)
    
    movedBefore: (id, before) ->
      console.log("movedBefore", id, before)
    
    removed: (id) ->
      console.log("removed", id)
    
  Meteor.subscribe('double')
  

# Open up the console on the client and you'll see 10
# added messages but no changes messages!

# added x0 Object {}
# added x1 Object {}
# added x2 Object {}
# added x3 Object {}
# added x4 Object {}
# added x5 Object {}
# added x6 Object {}
# added x7 Object {}
# added x8 Object {}
# added x9 Object {}

# Use the [DDP Analyser](https://github.com/arunoda/meteor-ddp-analyzer) and you'll
# see that the changes aren't even picked up!