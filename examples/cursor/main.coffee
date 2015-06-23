# This demonstrates that passing the subscription as a cursor works
# using meteor add zodern:nice-reload so use ctrl+l to make sure
# that hot reloads dont fuck this up -- hot reloads send all the added 
# messages all over again.
#
# Actually, that doesnt show the issue. If the server restarts, then
# we can get an issue. 

if Meteor.isServer
  doc = (i) ->
    {_id:i, value:i}
  docs = null
  
  DB.publish 'numbers', 2000, (n) ->
    if docs
      i = Random.choice([0...docs.length])
      j = Random.choice([0...docs.length-1])
      doc = docs[i]
      docs.splice(i,1)
      docs.splice(j,0,doc)
      return R.clone(docs)
    else
      docs = R.map(doc, [0...n])
      return R.clone(docs)

if Meteor.isClient
  @sub = DB.subscribe('numbers', 20)    

  Template.fetch.helpers
    numbers: () ->
      sub.fetch()

  Template.cursor.helpers
    numbers: () -> 
      sub
