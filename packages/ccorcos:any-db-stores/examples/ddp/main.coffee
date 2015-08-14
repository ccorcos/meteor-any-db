if Meteor.isServer
  # remember, we aren't using minimongo!
  Rooms = new Mongo.Collection('rooms')
  Messages = new Mongo.Collection('messages')

# a cursor, ordered publication
@RoomsStore = createDDPStore 'rooms', {minutes:2, ordered:true, cursor:true}, () ->
  syncDelay 500, -> Rooms.find({}, {sort:{createdAt:-1}})

# a non-cursor, unordered publication
@MessagesStore = createDDPListStore 'messages', {
    minutes:2,
    limit:5,
    ordered:true,
    cursor:false
  }, (roomId, {limit, offset}) ->
    syncDelay 500, -> Messages.find({roomId}, {sort:{createdAt:-1}, limit:limit+offset}).fetch()

Meteor.methods
  newRoom: (name) ->
    check(name, String)
    id = null
    if Meteor.isServer
      id = Rooms.insert({name, createdAt: Date.now()})
    RoomsStore.update undefined, (rooms) ->
      [{_id:Random.hexString(10), name, createdAt:Date.now(), unverified:true}].concat(rooms)
    return id
  newMsg: (roomId, text) ->
    check(roomId, String)
    check(text, String)
    if Meteor.isServer
      Messages.insert({roomId, text, createdAt: Date.now()})
    MessagesStore.update roomId, (messages) ->
      [{_id:Random.hexString(10), roomId, text, createdAt:Date.now(), unverified:true}].concat(messages)

if Meteor.isClient

  onEnter = (f) -> (e) ->
    if e.key is "Enter"
      e.preventDefault()
      f()

  createView = (spec) ->
    React.createFactory(React.createClass(spec))

  cond = (condition, result, otherwise) -> if condition then result else otherwise

  {div, input, button} = React.DOM

  # I prefer composable component to mixins
  StoreData = createView
    displayName: 'StoreData'
    mixins: [React.addons.PureRenderMixin]
    propTypes:
      query: React.PropTypes.any
      store: React.PropTypes.object.isRequired
      render: React.PropTypes.func.isRequired
    getInitialState: ->
      {data, fetch, clear, watch} = @props.store.get(@props.query)
    componentWillMount: ->
      @listener = @state.watch (nextState) => @setState(nextState)
      if @state.data or not @state.fetch
        @setState({loading: false})
      else
        @fetch()
    fetch: ->
      @setState({loading:true})
      @state.fetch => @setState({loading:false})
    componentWillUnmount: ->
      @listener.stop()
      @state.clear()
    render: ->
      @props.render({
        data: @state.data
        fetch: if @state.fetch then @fetch else null
        loading: @state.loading
      })

  App = createView
    displayName: 'App'
    mixins: [React.addons.PureRenderMixin, React.addons.LinkedStateMixin]
    getInitialState: ->
      roomId: null
      newRoomName: ''
      newMsgText: ''
    newRoom: ->
      if @state.newRoomName.length > 0
        Meteor.call 'newRoom', @state.newRoomName, (err, roomId) => @setState({roomId})
        @setState({newRoomName:''})
    newMsg: ->
      if @state.newMsgText.length > 0 and @state.roomId
        Meteor.call 'newMsg', @state.roomId, @state.newMsgText
        @setState({newMsgText:''})
    renderRooms: ({data, loading}) ->
      div {className: 'rooms'},
        data?.map (room) =>
          selected = (if @state.roomId is room._id then 'selected' else '')
          unverified = (if room.unverified then 'unverified' else '')
          className  = "row #{unverified} #{selected}"
          (div {
            className
            key: room._id
            onClick: => @setState({roomId: room._id})
          }, room.name)
        cond @state.loading,
          (div {className: 'loading'}, 'loading...')
    renderMsgs: ({data, loading, fetch}) ->
      div {className: 'messages'},
        data?.map (msg) =>
          unverified = (if msg.unverified then 'unverified' else '')
          className  = "row #{unverified}"
          (div {className, key: msg._id,}, msg.text)
        cond loading,
          (div {className: 'loading'}, 'loading...')
          cond fetch,
            (button {className: 'fetch', onClick: fetch}, 'load more')
    render: ->
      div {className: 'wrapper'},
        div {className: 'rooms'},
          div {className: 'row'},
            input
              onKeyDown: onEnter(@newRoom)
              valueLink: @linkState('newRoomName')
              placeholder: 'new chatroom name'
          StoreData
            query: undefined
            # pass roomId prop to make sure renderRooms gets
            # called when a roomId changes.
            roomId: @state.roomId
            key: 'rooms-list'
            store: RoomsStore
            render: @renderRooms
        div {className: 'messages'},
          cond @state.roomId,
            div {className:'row'},
              input
                onKeyDown: onEnter(@newMsg)
                valueLink: @linkState('newMsgText')
                placeholder: 'type a message here'
          cond @state.roomId,
            StoreData
              query: @state.roomId
              key: @state.roomId + '-messages'
              store: MessagesStore
              render: @renderMsgs

  Meteor.startup ->
    React.render(App({}), document.body)
