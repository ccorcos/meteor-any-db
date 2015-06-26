_.extend(this, R.pick([
  'curry'
  '__'
  'compose'
  'pipe'
  'concat'
  'append'
  'drop'
  'take'
  'split'
  'join'
  'replace'
  'map'
  'reduce'
  'filter'
  'prop'
  'eq'
  'propEq'
  'contains'
  'pluck'
  'pick'
  'omit'
  'merge'
  'assoc'
  'tap'
], R))

@log = (x) ->
  console.log(x)
  return x

React.initializeTouchEvents(true)
# to get :active pseudoselector working
document.addEventListener("touchstart", (()->), false)
# also need cursor:pointer to work on mobile
