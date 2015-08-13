
# Some utilities to slow down publications so we can see latency compensation in action
if Meteor.isServer
  Future = Npm.require('fibers/future')

  syncify = (f) ->
    (args...) ->
      fut = new Future()
      callback = Meteor.bindEnvironment (error, result) ->
        if error
          fut.throw(error)
        else
          fut.return(result)
      f.apply(this, args.concat(callback))
      return fut.wait()

  delay = (ms, f) -> Meteor.setTimeout(f, ms)

  delayWithCallback = (ms, func, callback) ->
    delay ms, -> callback(null, func())

  syncDelay = syncify(delayWithCallback)

# define server database
if Meteor.isServer
  Rooms = new Mongo.Collection('rooms')
  Messages = new Mongo.Collection('messages')

@RoomStore = createDDPStore 'rooms', {minutes:2, ordered:true, cursor:false}, () ->
  syncDelay 300, -> Rooms.find({}, {sort:{createdAt:-1}}).fetch()

@MessageStore = createDDPListStore 'messages', {
    minutes:2,
    limit:5,
    ordered:true,
    cursor:false
  }, (roomId, {limit, offset}) ->
    syncDelay 300, -> Messages.find({roomId}, {sort:{createdAt:-1}, limit:limit+offset}).fetch()

Meteor.methods
  newRoom: (name) ->
    check(name, String)
    id = null
    if Meteor.isServer
      id = Rooms.insert({name, createdAt: Date.now()})
    RoomStore.update undefined, (rooms) ->
      [{_id:Random.hexString(10), name, createdAt:Date.now(), unverified:true}].concat(rooms)
    return id
  newMsg: (roomId, text) ->
    check(roomId, String)
    check(text, String)
    if Meteor.isServer
      Messages.insert({roomId, text, createdAt: Date.now()})
    MessageStore.update roomId, (messages) ->
      [{_id:Random.hexString(10), roomId, text, createdAt:Date.now(), unverified:true}].concat(messages)

if Meteor.isClient

  blurOnEnterTab = (e) ->
    if e.key is "Tab" or e.key is "Enter"
      e.preventDefault()
      $(e.target).blur()

  createView = (spec) ->
    React.createFactory(React.createClass(spec))

  {div, input} = React.DOM

  StoreMixin =
    getInitialState: ->
      {data, fetch, clear, watch} = @getFromStore()
    loadMore: ->
      @setState({loading: true})
      @storeListener?.stop?()
      @state.fetch (nextState) =>
        nextState.loading = false
        @setState(nextState)
        @storeListener = nextState.watch? (nextState) => @setState(nextState)
    componentWillMount: ->
      if @state.data is null or @state.data is undefined
        @loadMore()
      else
        @setState({loading: false})
        @storeListener = @state.watch? (nextState) => @setState(nextState)
    componentWillUnmount: ->
      @storeListener?.stop?()
      @state.clear()

  StoreData = createView
    displayName: 'StoreData'
    mixins: [React.addons.PureRenderMixin, StoreMixin]
    propTypes:
      query: React.PropTypes.any.isRequired
      store: React.PropTypes.object.isRequired
      render: React.PropTypes.func.isRequired
    getFromStore: ->
      @props.store.get(@props.query)
    render: ->
      @props.render({
        data: @state.data
        loading: @state.loading
        loadMore: if @state.fetch then @loadMore else null
      })
      
  App = createView
    displayName: 'App'

    mixins: [
      React.addons.PureRenderMixin
      React.addons.LinkedStateMixin
    ]

    getInitialState: ->
      roomId: null
      newRoomName: ''
      newMsgText: ''

    newRoom: ->
      if @state.newRoomName.length > 0
        Meteor.call 'newRoom', @state.newRoomName, (err, roomId) => @setState({roomId})
        @setState({newRoomName:''})

    newMsg: (text) ->
      if @state.newMsgText.length > 0 and @state.roomId
        Meteor.call('newMsg', @state.roomId, @state.newMsgText)
        @setState({newMsgText:''})

    render: ->
      (div {className: 'wrapper'},
        (div {className: 'rooms'},
          (div {className: 'row'},
            (input {
              onKeyDown: blurOnEnterTab
              onBlur: @newRoom
              valueLink: @linkState('newRoomName')
              placeholder: 'NEW ROOM'
            }))
          (StoreData {
            query: undefined
            key: 0
            store: RoomStore
            render: ({loading, data, loadMore}) =>
              (div {},
                data?.map (room) =>
                  unverified = (if room.unverified then 'unverified' else '')
                  if loading
                    (div {}, loading)
                  else if @state.roomId is room._id
                    (div {
                      className: 'row selected ' + unverified
                      key: room._id
                    }, room.name)
                  else
                    (div {
                      className: 'row ' + unverified
                      key: room._id
                      onClick: => @setState({roomId:room._id})
                    }, room.name))
          })
        )
        (div {className: 'messages'},
          do =>
            if @state.roomId
              (div {className:'row'},
                (input {
                  onKeyDown: blurOnEnterTab
                  onBlur: @newMsg
                  valueLink: @linkState('newMsgText')
                  placeholder: 'NEW MESSAGE'
                }))
          do =>
            if @state.roomId
              (StoreData {
                query: @state.roomId
                key: @state.roomId + '-data'
                store: MessageStore
                render: ({data, loading, loadMore}) ->
                  if loading
                    (div {}, 'loading')
                  else
                    (div {},
                      data?.map (msg) ->
                        unverified = (if msg.unverified then 'unverified' else '')
                        (div {
                          key: msg._id,
                          className: 'row ' + unverified
                        }, msg.text)
                      do ->
                        if loadMore
                          (React.DOM.button {onClick:loadMore}, 'load more')
                    )
              })
        ))

  Meteor.startup ->
    React.render(App({}), document.body)
