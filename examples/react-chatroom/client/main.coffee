newId = -> Random.hexString(24)

App = createView
  displayName: 'App'
  
  mixins: [
    React.addons.PureRenderMixin
    React.addons.LinkedStateMixin
  ]

  propTypes:
    rooms: React.PropTypes.array.isRequired
    msgs: React.PropTypes.array.isRequired
    roomId: React.PropTypes.string

  getInitialState: ->
    room: ''
    msg: ''

  newRoom: ->
    if @state.room.length > 0
      id = newId()
      name = @state.room
      Meteor.call 'newRoom', id, name, (err, result) -> 
        if err
          Rooms.handleUndo(id)
          selectRoom(null)
      @state.room = ''

  newMsg: ->
    if @state.msg.length > 0 and @props.roomId
      id = Random.hexString(24)
      text = @state.msg
      roomId = @props.roomId
      Meteor.call 'newMsg', roomId, id, text, (err, result) -> 
        if err then Msgs[roomId].handleUndo(id)
      @state.msg = ''

  render: ->
    {div, input} = React.DOM

    (div {style:[Style.wrapper]},
      (div {style:[Style.left]},
        (div {style:[Style.row]},
          (input {
            onKeyDown: blurOnEnterTab
            onBlur:@newRoom
            valueLink:@linkState('room')
            placeholder: 'NEW ROOM'
          })
        )
        @props.rooms.map (room) =>
          if room._id is @props.roomId
            (div {
              style:[Style.row, Style.selected]
              key: room._id
            }, room.name)
          else
            (div {
              style:[Style.row]
              key: room._id
              onClick: -> selectRoom(room._id)
            }, room.name)
      )
      do =>
        if @props.roomId
          (div {style:[Style.right]},
            (div {style:[Style.row]},
              (input {
                onKeyDown: blurOnEnterTab
                onBlur:@newMsg
                valueLink:@linkState('msg')
                placeholder: 'NEW MESSAGE'
              })
            )
            @props.msgs.map (msg) ->
              (div {key: msg._id, style:[Style.row]}, msg.text)
          )
    )


render = (done) ->
  React.render(App(@State), document.body, done)

evolveState
  rooms: []
  roomId: null
  msgs: []

Meteor.startup ->
  render()

  @Rooms = DB.createSubscription('chatrooms')
  Rooms.start()
  Tracker.autorun ->
    # console.log "ROOMS CHANGED"
    evolveState
      rooms: Rooms.fetch()
    render()

  @Msgs = {}
  autorun = null
  @selectRoom = (roomId) ->
    # console.log "SELECT ROOM", roomId
    autorun?.stop?()
    if roomId
      Msgs[roomId] = msgs = DB.createSubscription('msgs', roomId)
      msgs.start()
      autorun = Tracker.autorun ->
        # console.log "MSGS CHANGED"
        evolveState
          msgs: msgs.fetch()
          roomId: roomId
        render()
    else
      evolveState
        msgs: []
        roomId: null
      render()
