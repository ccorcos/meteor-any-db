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
  
  # publish 5 numbers always
  DB.publish 'stat', 2000, () ->
    R.map(doc, [0...5])

  # publish the numbers changing so 
  # we can see how the numbers
  # clear this subscription, and overlap
  # the other subscription.
  x = false
  toggle = -> x = not x
  DB.publish 'changing', 2000, () ->
    if toggle()
      R.map(doc, [0...4])
    else
      R.map(doc, [0...6])

if Meteor.isClient
  @stat = DB.subscribe('stat')    
  @changing = DB.subscribe('changing')    

  Template.stat.helpers
    array: () -> stat.fetch()
    observe: () -> stat

  Template.changing.helpers
    array: () -> changing.fetch()
    observe: () -> changing
