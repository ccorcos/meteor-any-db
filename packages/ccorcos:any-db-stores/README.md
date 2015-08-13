# ccorcos:any-db-stores

This package was inspired by Facebook's Flux architecture and adds a layer on top of `ccorcos:any-db-pub-sub` providing subscription caching, client-side latency compensation, and a common way of handling data.

A "store" represents a place where data lives. There are 4 flavors which come with this package. Two deal with REST APIs, one with paging support (limit and offset) and one without. The other two deal with DDP subscriptions (from `ccorcos:any-db-pub-sub`) supporting reactive data, and again, one supports paging (just a limit parameter) and the other does not.

- createRESTStore

```coffee
WeatherStore = createRESTStore 'weather', {minutes:2}, (place, callback) ->
  HTTP.get 'http://api.openweathermap.org/data/2.5/weather', {params:{q:query}}, (err, result) ->
    if err then throw err
    callback(result.data)
```

- createRESTListStore

```coffee
FacebookUserStore = createRESTListStore 'facebook-users', {minutes:2, limit:10}, (name, {limit, offset}, callback) ->
  HTTP.get 'https://graph.facebook.com/v2.4/search', {params:{
    fields: 'name,picture{url}'
    type: 'user'
    q: name
    limit: limit
    offset: offset
    access_token: Meteor.user().services.facebook.accessToken
  }}, (err, result) ->
    if err then throw err
    callback(result.data)
```

- createDDPStore

```coffee
PostStore = createDDPStore 'posts', {ordered:false, cursor:false, minutes:2}, ([postId, userId]) ->
  unless userId is @userId
    throw new Meteor.Error(401, 'Dont try to spoof someone else...')
  Posts.find({_id:postId, owner:userId}).fetch()
```
- createDDPListStore

```coffee
MessageStore = createDDPStore 'messages', {ordered:true, cursor:false, minutes:2}, (roomId, {limit, offset}) ->
  Messages.find({roomId:roomId}, {limit: limit+offset, sort:{createdAt:-1}}).fetch()
```

The name given to the ddp store is used for migrating data between hot-reloads, much like `Session`.
The `minutes` option specifies how long a subscription is cached for after it is cleared.
For list stores, limit specifies how many items at a time you want, and in the fetcher function, you get a limit and an offset.
For REST stores, you're given an async callback. The DDP store handles publishing and subscribing to data. It is isomorphic, but the fetcher function is only ever run on the server and must be wrapped in a fiber.

All of the stores are used following the same general pattern: **get-(fetch|set)-(watch)-clear**. For example:

Here's the simplest example:

```coffee
{data, fetch, clear} = WeatherStore.get('san diego')
if data # if it was cached already
  @setState({weather:data})
else
  @setState({loading:true})
  fetch ({data}) => @setState({weather:data, loading:false})
# later on, set a timer to clear the subscription
clear()
```

For list data, `fetch` will be null if you cannot page anymore.

```coffee
{data, fetch, clear} = FacebookUserStore.get('charlie brown')
if data # if it was cached
  @setState({weather:data, loadMore:fetch})
else
  @setState({loading:true})
  fetch ({data, fetch}) => @setState({weather:data, loadMore:fetch})
# later on, set a timer to clear the subscription
clear()
```

For DDP stores, you can watch for changes as well.

```coffee
{data, fetch, clear, watch} = Messages.get(roomId)
listener = watch ({data, fetch}) => @setState({messages:data, fetch})
if data # if it was cached
  @setState({weather:data, loadMore:fetch})
else
  fetch()
# later on, we can fetch more:
@state.loadMore?()
# and eventually, we can set a timer to clear the subscription
clear()
```

## Latency Compensation

Latency compensation works by transforming the collection of data however you want and when the subscription changes, it will overwrite any changes you made to the store.

```coffee
Meteor.methods
  addMsg: (roomId, text) ->
    if Meteor.isServer
      Messages.insert({roomId, text})
    MessageStore.update roomId, (messages) ->
      [{roomId, text, unverified:true}].concat(messages)
```

This `store.update` is isomorphic -- on the client it will transform the data within the store but on the server, this function is never called and instead `refreshPub` is called on the appropriate subscriptions.
