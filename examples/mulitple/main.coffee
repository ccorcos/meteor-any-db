# This demonstrates that passing the subscription as a cursor works
# using meteor add zodern:nice-reload so use ctrl+l to make sure
# that hot reloads dont fuck this up -- hot reloads send all the added 
# messages all over again.
#
# Actually, that doesnt show the issue. If the server restarts, then
# we can get an issue. 


test = (msg, f) ->
  unless f() then throw new Error(msg)

if Meteor.isServer
  makeDoc = (i) ->
    {_id:"x#{i}", value:i}

  @reorderOne = (list) ->
    list = R.clone(list)
    if list.length > 0
      i = Random.choice([0...list.length])
      j = Random.choice([0...list.length-1])
      doc = list[i]
      list.splice(i,1)
      list.splice(j,0,doc)
    return R.clone(list)

  test '1',  ->
    reorderOne([]).length is 0
  test '2',  ->
    reorderOne([2]).length is 1
  test '3',  ->
    reorderOne([1,2,3]).length is 3

  @reorderN = (n, list) ->
    list = R.clone(list)
    for i in [0...n]
      list = reorderOne(list)
    return list

  test '11',  ->
    reorderN(2, []).length is 0
  test '12',  ->
    reorderN(2, [2]).length is 1
  test '13',  ->
    reorderN(2, [1,2,3]).length is 3

  @removeOne = (list) ->
    list = R.clone(list)
    if list.length > 0
      i = Random.choice([0...list.length])
      list.splice(i,1)
    return R.clone(list)

  test '21',  ->
    removeOne([]).length is 0
  test '22',  ->
    removeOne([2]).length is 0
  test '23',  ->
    removeOne([1,2,3]).length is 2

  @removeN = (n, list) ->
    list = R.clone(list)
    for i in [0...n]
      list = removeOne(list)
    return list

  test '31',  ->
    removeN(2, []).length is 0
  test '32',  ->
    removeN(2, [2]).length is 0
  test '33',  ->
    removeN(2, [1,2,3]).length is 1

  @addOne = (list) ->
    list = R.clone(list)
    values = if list.length > 0 then R.pluck('value',list) else []
    possiblities = R.difference([0...10], values)
    if possiblities.length > 0
      x = Random.choice(possiblities)
      if list.length > 0
        i = Random.choice([0...list.length])
        list.splice(i,0,makeDoc(x))
      else
        list.push(makeDoc(x))
    return R.clone(list)

  test '41',  ->
    addOne([]).length is 1
  test '42',  ->
    addOne([2]).length is 2
  test '43',  ->
    addOne([1,2,3]).length is 4
  test '44',  ->
    addOne(R.map(makeDoc, [0...10])).length is 10

  @addN = (n, list) ->
    list = R.clone(list)
    for i in [0...n]
      list = addOne(list)
    return list

  test '51',  ->
    addN(2, []).length is 2
  test '52',  ->
    addN(2, [2]).length is 3
  test '53',  ->
    addN(2, [1,2,3]).length is 5
  test '54',  ->
    addN(9, R.map(makeDoc, [1,2,3])).length is 10

  # This one has 5 docs and reorders them
  statDocs = R.map(makeDoc, [0...5])
  DB.publish 
    name: 'stat'
    ms: 1000, 
    query: () ->
      statDocs = reorderOne(statDocs)
      console.log "statDocs", R.pluck('value', statDocs)
      return statDocs

  # This one will have adding removing and reordering
  changingDocs = R.map(makeDoc, [3,4,5,6,7])
  DB.publish 
    name: 'changing'
    ms: 1000
    query: () ->
      console.log "changingDocs", R.pluck('value', changingDocs)
      what = Random.choice([1,2,3])
      howMany = Random.choice([1,2,3])
      if what is 1
        changingDocs = reorderN(howMany, changingDocs)
        return changingDocs
      if what is 2
        changingDocs = removeN(howMany, changingDocs)
        return changingDocs
      if what is 3
        changingDocs = addN(howMany, changingDocs)
        return changingDocs

if Meteor.isClient
  @stat = DB.createSubscription('stat')    
  @changing = DB.createSubscription('changing')   
  stat.start()
  changing.start() 

  Template.stat.helpers
    array: () -> stat.fetch()
    observe: () -> stat

  Template.changing.helpers
    array: () -> changing.fetch()
    observe: () -> changing
