if Meteor.isServer
  doc = (i) ->
    {_id:i, value:i}
  docs = null
  
  DB.publish 'numbers', 2000, (n) ->
    if docs
      i = Random.choice([0...docs.length])
      doc = docs[i]
      docs.splice(i,1)
      docs.unshift(doc)
      console.log "query"
      return R.clone(docs)
    else
      docs = R.map(doc, [0...n])
      console.log "query"
      return R.clone(docs)

if Meteor.isClient
  sub = DB.subscribe('numbers', 4)    

  Template.main.helpers
    numbers: () ->
      sub.fetch()