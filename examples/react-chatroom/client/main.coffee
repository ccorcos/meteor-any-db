# Styles using Radium: https://github.com/FormidableLabs/radium
Style = 
  wrapper:
    display: 'flex'
  left:
    flex: '0 0 250px'
    textAlign: 'center'
  right:
    flex: '1 1 0'
  row:
    padding: '5px'
  selected:
    backgroundColor: 'blue'
    color: 'white'
    borderRadius: '5px'


# This is a pretty simple chat app, so we're going 
# to do it all in one react component.
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
      id = DB.newId()
      name = @state.room
      Meteor.call 'newRoom', id, name, (err, result) -> 
        if err
          Rooms.handleUndo(id)
          selectRoom(null)
      @state.room = ''

  newMsg: ->
    if @state.msg.length > 0 and @props.roomId
      id = DB.newId()
      text = @state.msg
      roomId = @props.roomId
      Meteor.call 'newMsg', roomId, id, text, (err, result) -> 
        if err then Msgs[roomId].handleUndo(id)
      @state.msg = ''

  render: ->
    {div, input} = React.DOM

    (div {style:[Style.wrapper]},
      (div {style:[Style.left]},
        # new chatroom
        (div {style:[Style.row]},
          (input {
            onKeyDown: blurOnEnterTab
            onBlur:@newRoom
            valueLink:@linkState('room')
            placeholder: 'NEW ROOM'
          })
        )
        # list of chatrooms
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
            # new message
            (div {style:[Style.row]},
              (input {
                onKeyDown: blurOnEnterTab
                onBlur:@newMsg
                valueLink:@linkState('msg')
                placeholder: 'NEW MESSAGE'
              })
            )
            # list of messages
            @props.msgs.map (msg) ->
              (div {key: msg._id, style:[Style.row]}, msg.text)
          )
    )

# render the top-level component with the app state
render = (done) ->
  React.render(App(@State), document.body, done)

# set the initial state
evolveState
  rooms: []
  roomId: null
  msgs: []

Meteor.startup ->
  # initial render
  render()

  @Rooms = DB.createSubscription('chatrooms')
  Rooms.start()
  Tracker.autorun ->
    evolveState({rooms: Rooms.fetch()})
    render()

  @Msgs = {}
  # wrap the subscription in an autorun it will automatically
  # stop when the autorun is stopped.
  autorun = null
  @selectRoom = (roomId) ->
    autorun?.stop?()
    if roomId
      msgs = Msgs[roomId]
      unless msgs
        Msgs[roomId] = msgs = DB.createSubscription('msgs', roomId)
      autorun = Tracker.autorun ->
        msgs.start()
        Tracker.autorun ->
          evolveState
            msgs: msgs.fetch()
            roomId: roomId
          render()
    else
      evolveState
        msgs: []
        roomId: null
      render()
