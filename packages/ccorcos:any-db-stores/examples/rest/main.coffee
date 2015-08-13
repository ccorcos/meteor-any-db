
if Meteor.isClient

  blurOnEnterTab = (e) ->
    if e.key is "Tab" or e.key is "Enter"
      e.preventDefault()
      $(e.target).blur()

  createView = (spec) ->
    React.createFactory(React.createClass(spec))

  {div, input} = React.DOM

  @WeatherStore = createRESTStore 'weather', {minutes:2}, (place, callback) ->
    HTTP.get 'http://api.openweathermap.org/data/2.5/weather', {params:{q:place}}, (err, result) ->
      if err then throw err
      callback(result.data)

  App = createView
    displayName: 'App'

    mixins: [
      React.addons.PureRenderMixin
      React.addons.LinkedStateMixin
    ]

    searchWeather: ->
      # clear last search
      @state?.clear?()
      {data, fetch, clear} = WeatherStore.get(@state.query)
      if data
        @setState({data, clear, query:''})
      else
        @setState({data, clear, query:'', loading:true})
        fetch ({data}) => @setState({data, loading:false})

    componentWillUnmount: ->
      @state.clear?()

    getInitialState: ->
      clear: null
      data: null
      loading: false
      query: ''

    render: ->
      (div {className: 'wrapper'},
        (div {className: 'row'},
          (input {
            onKeyDown: blurOnEnterTab
            onBlur: @searchWeather
            valueLink: @linkState('query')
            placeholder: 'search a city'
          }))
        do =>
          if @state.loading
            (div {className: 'row'}, 'loading...')
          else
            (div {className: 'row'}, @state.data?.weather?[0]?.description)
      )
  Meteor.startup ->
    React.render(App({}), document.body)
